#!/bin/bash --norc
#
# Copyright 2017 Sandro Marcell <smarcell@mail.com>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
# MA 02110-1301, USA.
#
PATH='/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin'
export LC_ALL=POSIX

# Start of GLOBAL VARIABLES
#
# Directory where rrdtool databases will be stored
RRD_DB='/var/db/rrd/rrd-rttping'

# Directory on the web server where the generated html/png files will be stored
HTML_DIR='/srv/http/lighttpd/htdocs/rrd-rttping'

# Generate charts for the following periods
PERIODS='day week month year'

# Resolution time in seconds of RRD bases (default 5 minutes)
# Note: change this value only if you really know what you are doing!
INTERVAL=$((60 * 5))

##
## Array with the equipment definitions and their respective ip's
## ATTENTION: when adding new entries, ALWAYS KEEP the correct order and sequence of the indices of this array!
##
declare -a HOSTS
# Eg. modem
HOSTS[0]='Modem Zyxel'
HOSTS[1]='192.168.64.1'
# Eg. router 1
HOSTS[2]='OpenWrt'
HOSTS[3]='10.11.12.1'
# Eg. router 2
HOSTS[4]='OpenWrt-Rpt'
HOSTS[5]='10.11.12.2'
#
# End of GLOBAL VARIABLES

# Working directories
[ ! -d "$RRD_DB" ] && { mkdir -p "$RRD_DB" || exit 1; }
[ ! -d "$HTML_DIR" ] && { mkdir -p "$HTML_DIR" || exit 1; }

generateGraphs() {
	declare -a args=("${HOSTS[@]}")
	declare -a latency=(0 0 0)
	declare host=''
	declare ip=''
	declare ping_status=0
	declare loss=0
	declare rtt_min=0
	declare rtt_avg=0
	declare rtt_max=0

	while [ ${#args[@]} -ne 0 ]; do
		host="${args[0]}" # Equipament name
		ip="${args[1]}" # IP address
		args=("${args[@]:2}")

		ping_status=$(ping -4qnU -c 5 -W 1 $ip)
		[ $? -eq 0 ] && latency=($(echo $ping_status | awk -F '/' 'END {print $4,$5,$6}' | grep -oP '\d.+'))
		loss=$(echo "$ping_status" | grep -oP '\d+(?=% packet loss)')

		# Latencies: min, avg and max
		rtt_min="${latency[0]}"
		rtt_avg="${latency[1]}"
		rtt_max="${latency[2]}"

		# If the rrd bases do not exist, they will be created and each will have the same name as the monitored IP
		if [ ! -e "${RRD_DB}/${ip}.rrd" ]; then
			# Resolution = Number of seconds in the period / (Resolution interval * Resolution multiplication factor)
			v1hr=$((604800 / (INTERVAL * 12))) # Value of 1 week (1h resolution)
			v6hrs=$((2629800 / (INTERVAL * 72))) # Value of 1 month (6h resolution)
			v24hrs=$((31557600 / (INTERVAL * 288))) # Value of 1 year (24h resolution)

			echo "Creating rrd base: ${RRD_DB}/${ip}.rrd"
			rrdtool create ${RRD_DB}/${ip}.rrd --start $(date '+%s') --step $INTERVAL \
				DS:min:GAUGE:$((INTERVAL * 2)):0:U \
				DS:avg:GAUGE:$((INTERVAL * 2)):0:U \
				DS:max:GAUGE:$((INTERVAL * 2)):0:U \
				DS:loss:GAUGE:$((INTERVAL * 2)):0:U \
				RRA:MIN:0.5:1:288 \
				RRA:MIN:0.5:12:$v1hr \
				RRA:MIN:0.5:72:$v6hrs \
				RRA:MIN:0.5:288:$v24hrs \
				RRA:AVERAGE:0.5:1:288 \
				RRA:AVERAGE:0.5:12:$v1hr \
				RRA:AVERAGE:0.5:72:$v6hrs \
				RRA:AVERAGE:0.5:288:$v24hrs \
				RRA:MAX:0.5:1:288 \
				RRA:MAX:0.5:12:$v1hr \
				RRA:MAX:0.5:72:$v6hrs \
				RRA:MAX:0.5:288:$v24hrs
			[ $? -gt 0 ] && return 1
		fi

		# If the bases already exist, update them...
		echo "Updating base: ${RRD_DB}/${ip}.rrd"
		rrdtool update ${RRD_DB}/${ip}.rrd --template loss:min:avg:max N:${loss}:${rtt_min}:${rtt_avg}:$rtt_max
		[ $? -gt 0 ] && return 1

		# and create the charts
		for i in $PERIODS; do
			case $i in
				  'day') inf='Daily graph (5 min average)'; p='1day' ;;
				 'week') inf='Weekly graph (1 hr average)'; p='1week' ;;
				'month') inf='Monthly graph (6 hrs average)'; p='1month' ;;
				 'year') inf='Annual graph (24 hrs average)'; p='1year' ;;
			esac

			rrdtool graph ${HTML_DIR}/${ip}-${i}.png --start end-$p --end now --step $INTERVAL --font 'TITLE:0:Bold' --title "$inf" \
				--lazy --watermark "$(date '+%^c')" --vertical-label 'Latency (ms)' --slope-mode --interlaced --alt-y-grid --alt-autoscale \
				--rigid --lower-limit 0 --units-exponent 0 --imgformat PNG --height 124 --width 550 \
				--color 'BACK#F8F8FF' --color 'SHADEA#FFFFFF' --color 'SHADEB#FFFFFF' \
				--color 'MGRID#AAAAAA' --color 'GRID#CCCCCC' --color 'ARROW#333333' \
				--color 'FONT#333333' --color 'AXIS#333333' --color 'FRAME#333333' \
				DEF:rtt_min=${RRD_DB}/${ip}.rrd:min:MIN \
				DEF:rtt_avg=${RRD_DB}/${ip}.rrd:avg:AVERAGE \
				DEF:rtt_max=${RRD_DB}/${ip}.rrd:max:MAX \
				DEF:rtt_loss=${RRD_DB}/${ip}.rrd:loss:AVERAGE \
				VDEF:vmin=rtt_min,MINIMUM \
				VDEF:vavg=rtt_avg,AVERAGE \
				VDEF:vmax=rtt_max,MAXIMUM \
				VDEF:vloss=rtt_loss,AVERAGE \
				"COMMENT:$(printf '%5s')" \
				"LINE1:rtt_min#00990095:Minimun\:$(printf '%3s')" \
				GPRINT:vmin:"%1.3lfms\l" \
				"COMMENT:$(printf '%5s')" \
				"LINE1:rtt_max#99000095:Maximun\:$(printf '%3s')" \
				GPRINT:vmax:"%1.3lfms\l" \
				"COMMENT:$(printf '%5s')" \
				"LINE1:rtt_avg#0066CC95:Average\:$(printf '%3s')" \
				GPRINT:vavg:"%1.3lfms\l" \
				"COMMENT:$(printf '%5s')" \
				"COMMENT:Lost packets\:" \
				GPRINT:vloss:"%1.0lf%%\l" 1> /dev/null
			[ $? -gt 0 ] && return 1
		done
	done
	return 0
}

generateHTML() {
	declare -a args=("${HOSTS[@]}")
	declare -a ips
	declare host=''
	declare ip=''
	declare title='ROUND-TRIP TIME PING GRAPHS'

	# Filtering the $HOSTS array to return ip address
	for ((i = 0; i <= ${#HOSTS[@]}; i++)); do
		((i % 2 == 1)) && ips+=("${HOSTS[$i]}")
	done

	echo 'Creating HTML pages...'

	# 1 - The index page
	cat <<- FIM > ${HTML_DIR}/index.html
		<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN"
		"http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
		<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en">
		<head>
		<title>${0##*/}</title>
		<meta http-equiv="content-type" content="text/html;charset=utf-8" />
		<meta name="generator" content="Geany 1.24.1" />
		<meta name="author" content="Sandro Marcell" />
		<style type="text/css">
			* { box-sizing: border-box; }
			html, body { margin:0; padding:0; background:#DDD; color:#333; font: 14px/1.5em Helvetica, Arial, sans-serif; }
			a { text-decoration: none; color: #C33; }
			header, footer, article, nav, section { float: left; padding: 10px; }
			header,footer { width:100%; }
			header, footer { background-color: #333; color: #FFF; text-align: right; height: 100px; }
			header { font-size: 1.8em; font-weight: bold; }
			footer{ background-color: #999; text-align: center; height: 40px; }
			nav { text-align: center; width: 24%; margin-right: 1%; border: 1px solid #CCC; margin:5px; margin-top: 10px; }
			nav a { display: block; width: 100%; background-color: #C33; color: #FFF; height: 30px; margin-bottom: 10px; padding: 10px; border-radius: 3px; line-height: 10px; vertical-align: middle; }
			nav a:hover, nav a:active { background-color: #226; }
			article { width: 75%; height: 1200px; }
			h1 { padding: 0; margin: 0 0 20px 0; text-align: center; }
			p { text-align: center; margin-top: 30px; }
			article section { padding: 0; width: 100%; }
			.container{ width: 1200px; float: left; position: relative; left: 50%; margin-left: -600px; background:#FFF; padding: 10px; }
			.content { width: 100%; height: 100%; overflow: hidden;}
			.hide { display: none; }
		</style>
		<script type="text/javascript">
			function showGraphs(id) {
				document.getElementById('obj').innerHTML = document.getElementById(id).innerHTML;
			}
		</script>
		</head>
		<body>
		<div class="container">
			<nav>
				$(while [ ${#args[@]} -ne 0 ]; do
					host="${args[0]}"
					ip="${args[1]}"
					args=("${args[@]:2}")
					echo "<a href="\"javascript:showGraphs\("'$ip'"\)\;\"">$host</a>"
				done)
			</nav>
			<article>
				<h1>$title</h1>
				<div id="obj" class="content"><p>&#10229; Click on the menu to view the graphs.</p></div>
				<section>
					$(for i in "${ips[@]}"; do
						echo "<div id="\"$i\"" class="\"hide\""><object type="\"text/html\"" data="\"${i}.html\"" class="\"content\""></object></div>"
					done)
				</section>
			</article>
			<footer>
				<small>${0##*/} &copy; 2017-$(date '+%Y') <a href="https://gitlab.com/smarcell">Sandro Marcell</a></small>
			</footer>
		</div>
	</body>
	</html>
FIM

	# 2o: Specific page for each host with the defined periods
	while [ ${#HOSTS[@]} -ne 0 ]; do
		host="${HOSTS[0]}"
		ip="${HOSTS[1]}"
		HOSTS=("${HOSTS[@]:2}")

		cat <<- FIM > ${HTML_DIR}/${ip}.html
		<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN"
		"http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
		<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en">
		<head>
		<title>${0##*/}</title>
		<meta http-equiv="content-type" content="text/html;charset=utf-8" />
		<meta name="author" content="Sandro Marcell" />
		<style type="text/css">
		body { margin: 0; padding: 0; background-color: #FFFFFF; width: 100%; height: 100%; font: 20px/1.5em Helvetica, Arial, sans-serif; }
		#header { text-align: center; }
		#content { position: relative; text-align: center; margin: auto; }
		#footer { font-size: 13px; text-align: center; }
		</style>
		<script type="text/javascript">
			var refresh = setTimeout(function() {
				window.location.reload(true);
			}, $((INTERVAL * 1000)));
		</script>
		</head>
		<body>
			<div id="header">
				<p>$host<br /><small>($ip)</small></p>
			</div>
			<div id="content">
				<script type="text/javascript">
					$(for i in $PERIODS; do
						echo "document.write('<div><img src="\"${ip}-${i}.png?nocache=\' + \(Math.floor\(Math.random\(\) \* 1e20\)\).toString\(36\) + \'\"" alt="\"${0##*/} --html\"" /></div>');"
					done)
				</script>
			</div>
		</body>
		</html>
FIM
	done
	return 0
}

# Create the html files
# Script call: ./rrd-rttping.sh --html
if [ "$1" == '--html' ]; then
	generateHTML
	exit 0
fi

# Collecting data and generating charts
# Script call: ./rrd-rttping.sh
generateGraphs