#!/bin/bash

# tested with ISE 2.2
# 3. Mai 2018

# exit codes:
# 0 - specific operation went OK (IMPORT / EXPORT / DELETE), 
# 1 - error while doing a specific operation (IMPORT / EXPORT / DELETE) -> check $ERROR_LOG,
# 2 - cmdline args missing
# 3 - no connect to ISE ERS API possible, 
# 4 - group not found, 
# 5 - profile not found, 
# 6 - MAC not found 
# 7 - CSV file not found

# updated 29. Mai 2018
# - implement functions to import, update and delete endpoints
# - check ISE ers connect with given credentials

# 31. Mai add proper cmdline handling
# todo: - minimize json objects to nescessary key-value-pairs - DONE
# 	- add csvimport - DONE
# 	- rework logging

OK_COUNT=0
PROBLEM_COUNT=0
TOTAL_COUNT=0

IMPORTED_LOG="ise_ers_imported.log"
NOT_IMPORTED_LOG="ise_ers_not_imported.log"
ERROR_LOG="ise_ers_error.log"

help_args(){
	echo -e "$0\n\
	\t-h --help [print this help]\n\
	\t-a --action [IMPORT | UPDATE | DELETE]\n\
	\t-u --user\n\
	\t-p --password\n\
	\t-m --mac-address [provided in format \"aa:bb:cc:dd:ee:ff\"]\n\
	\t-H --host [IP or Hostname of ISE]\n\
	\t-P --profilename [profile which endpoint should be linked to]\n\
	\t-g --groupname [group which endpoint should be linked to]\n\
	\t-c --csvfile [expected in format: \$MAC;\$DESCRIPTION;\$GROUP;\$PROFILE]\n"
	exit 2
}
get_args(){
	while [ "$1" != "" ]; do
		PARAM=`echo $1`
		VALUE=`echo $2`
		case $PARAM in
			-h | --help)
				help_args
				;;
			-a | --action)
				ACTION="$VALUE"
				if [[ $ACTION != @("IMPORT"|"UPDATE"|"DELETE") ]]; then
					echo "ACTION unknown, exit"
					help_args
				fi
				;;
			-u | --user)
				USER="$VALUE"
				;;
			-p | --password)
				PASSWORD="$VALUE"
				;;
			-m | --mac-address)
				MAC="$VALUE"
				#test MAC format aa:bb:cc:dd:ee:ff
				check_mac_format
				;;
			-H | --host)
				ISE_HOST="$VALUE"
				;;
			-P | --profilename)
				PROFILENAME="$VALUE"
				;;
			-g | --groupname)
				GROUPNAME="$VALUE"
				;;
			-c | --csvfile)
				CSVFILE="$VALUE"
				;;
			*)
			echo "ERROR: unknown parameter \"$PARAM\""
			help_args	
			;;
		esac
		#shift to next key-value-pair
		shift; shift;
	done
	if [[ $ACTION == "" || $USER == "" || $PASSWORD == "" || $ISE_HOST == "" || ($CSVFILE == "" && $MAC == "") ]]; then
		echo Missing arguments, exit
		help_args
	elif [[ $CSVFILE != "" && $MAC != "" ]]; then
	        echo You can not provide MAC and CSV list at the same time, exit. 
                help_args
        fi

	# groupname and / or profilename are not mandatory
	# but we need to know whether these args are set
	# to construct a proper json request
	if [[ $GROUPNAME == "" ]]; then
		GROUPNAME=""
		STATIC_GROUP_BOOL="false"
	else
		STATIC_GROUP_BOOL="true"
	fi
	if [[ $PROFILENAME == "" ]]; then
		PROFILENAME=""
		STATIC_PROFILE_BOOL="false"
	else
		STATIC_PROFILE_BOOL="true"
	fi
		
}
test_connection(){
	# test connection, else exit
	# better test against actual API (GET)
	echo "Testing connection to $ISE_HOST"
	curl --connect-timeout 3 -s -k -v --user $USER:$PASSWORD https://$ISE_HOST:9060/ers/sdk 2>&1 | grep -q "HTTP/1.1 200 OK"
	if [[ $? -ne 0 ]]; then
		echo "Can't connect to ISE API, check IP/Hostname, ERS Credentials and whether ERS service is active. Exit."
		exit 3
	else
		echo '-> OK'
	fi
}

script_status(){
	if [[ $ACTION_OK -eq 1 ]]; then
		echo "Submission of MAC: $MAC with action $ACTION went good. Group: \"$GROUPNAME\", Profile: \"$PROFILENAME\""
	else
		echo "Submission of MAC: $MAC with action $ACTION had a problem."
		# needs proper error handling
		echo "Timestamp `date '+%s'`: $MAC, ACTION: $ACTION" >> $ERROR_LOG
		echo "Timestamp `date '+%s'`: $MAC, ACTION: $ACTION" >> $NOT_IMPORTED_LOG
		# append to last error log entry for better overview
		echo "+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++" >> $ERROR_LOG
		let "PROBLEM_COUNT+=1"
		echo "Issues (`echo $NOT_IMPORTED_LOG`) Current issue count: `wc -l < $NOT_IMPORTED_LOG`"
		echo "ERS Error Log: $ERROR_LOG"
	fi
}

get_group_by_id(){
	#groupname is case-insensitive in ISE
	#get group UUID
	GROUPID=`curl -s -k \
	-H 'Content-type: application/json' \
	-H 'Accept: application/json' \
	-H 'ERS-Media-Type: identity.endpointgroup.1.0' \
	--user $USER:$PASSWORD \
	https://$ISE_HOST:9060/ers/config/endpointgroup?filter=name.EQ.$GROUPNAME \
	| grep '"id"' | grep -Eo '[a-f0-9-]{36}'`

	if [[ $GROUPID == "" && $STATIC_GROUP_BOOL == "true" ]]; then
		##response empty? -> exit
	        echo "Could not find group: \"$GROUPNAME\" in ISE database, exit."
	        exit 4;
	fi
}

get_profile_by_id(){
        #profile is case-insensitive in ISE
        #get profile UUID
        PROFILEID=`curl -s -k \
        -H 'Content-type: application/json' \
        -H 'Accept: application/json' \
        -H 'ERS-Media-Type: identity.profilerprofile.1.0' \
        --user $USER:$PASSWORD \
        https://$ISE_HOST:9060/ers/config/profilerprofile?filter=name.EQ.$PROFILENAME \
        | grep '"id"' | grep -Eo '[a-f0-9-]{36}'`

	if [[ $PROFILEID == "" && $STATIC_PROFILE_BOOL == "true" ]]; then
		##response empty? -> exit
	        echo "Could not find profile: \"$PROFILENAME\" in ISE database, exit."
	        exit 5;
	fi
}

get_mac_by_id(){
	#MAC adress is case-insensitive in ISE
	#get MAC endpoint UUID
	MACID=`curl -k -s \
	-H "Accept: application/json" \
	-H "Content-Type: application/json" \
	-H "ERS-Media-Type: identity.endpoint.1.2" \
	--user $USER:$PASSWORD https://$ISE_HOST:9060/ers/config/endpoint?filter=mac.EQ.$MAC \
	| grep '"id"' | grep -Eo '[a-f0-9-]{36}'`
	#response empty? -> exit, if in CSV mode -> skip entry
	if [[ $MACID == "" && ($ACTION == "DELETE" || $ACTION == "UPDATE") && $CSVFILE != "" ]]; then
		echo "Could not find MAC address: \"$MAC\" in ISE database, skipping entry."
		return 666 
	elif [[ $MACID == "" ]]; then
		echo "Could not find MAC address: \"$MAC\" in ISE database, exit."
		exit 6;
	fi
}

check_mac_format(){
	echo -n $MAC | grep -Eq "^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$"
        if [[ $? -ne 0 ]]; then
        	echo "Wrong MAC format, exit"
                help_args
        fi
}



import_endpoint(){
	# if something is grepped here, there was an ERS response which is bad
	echo -n "$json_obj" \
	| curl -s -k -X POST \
	-H 'Content-type: application/json' \
	-H 'Accept: application/json' \
	-H 'ERS-Media-Type: identity.endpoint.1.2' \
	--user $USER:$PASSWORD \
	--data @- https://$ISE_HOST:9060/ers/config/endpoint/ \
	| grep -A100 -B10 "ERSResponse" >> $ERROR_LOG \
	|| ACTION_OK=1
}
update_endpoint(){
	# if something is grepped here, there was an ERS response which is bad
	echo -n "$json_obj" \
	| curl -X PUT -s -k -T - \
	-H 'Content-type: application/json' \
	-H 'Accept: application/json' \
	-H 'ERS-Media-Type: identity.endpoint.1.2' \
	--user $USER:$PASSWORD \
	https://$ISE_HOST:9060/ers/config/endpoint/$MACID \
	| grep -A100 -B10 "ERSResponse" >> $ERROR_LOG \
	|| ACTION_OK=1
}

delete_endpoint(){
	# if something is grepped here, there was an ERS response which is bad
	curl -s -X DELETE -k \
	-H 'Content-type: application/json' \
	-H 'Accept: application/json' \
	-H 'ERS-Media-Type: identity.endpoint.1.2' \
	--user $USER:$PASSWORD \
	https://$ISE_HOST:9060/ers/config/endpoint/$MACID \
	| grep -A100 -B10 "ERSResponse" >> $ERROR_LOG \
	|| ACTION_OK=1
}

check_csv(){
	if [[ $CSVFILE == "" ]]; then
		return;
	fi
	echo Prechecking CSV file
	CSVLINES=`wc -l < $CSVFILE`
	LINES_CHECKED="0"
	for i in `cat $CSVFILE`; do
		parse_csv "$i"
		check_mac_format
		# ++1
		let "LINES_CHECKED+=1"
		#precheck csv format if ACTION == UPDATE OR IMPORT
		echo "Checking line $LINES_CHECKED / $CSVLINES"
		if [[ $ACTION != "DELETE" ]]; then
			#ignore if values are empty (-> Import to "Unknown")
			if [[ $PROFILENAME != "" ]]; then
				get_profile_by_id
			fi
			if [[ $GROUPNAME != "" ]]; then
				get_group_by_id
			fi
			reset_vars
		fi
	done
	echo Starting CSV run with ACTION: $ACTION
}

parse_csv(){
	MAC=`echo -n $1 | cut -d';' -f1`
	DESCRIPTION=`echo -n $1 | cut -d';' -f2`
	GROUPNAME=`echo -n $1 | cut -d';' -f3`
	PROFILENAME=`echo -n $1 | cut -d';' -f4`

	if  [[ $GROUPNAME == ""  ]]; then
		STATIC_GROUP_BOOL="false"
	fi
	if [[ $PROFILENAME == "" ]]; then
		STATIC_PROFILE_BOOL="false"
	fi
}

reset_vars(){
	#reset BOOLEAN vars for group and profile assignment to true
	STATIC_GROUP_BOOL="true"
	STATIC_PROFILE_BOOL="true"
	MACID=""
	PROFILENAME=""
	PROFILEID=""
	GROUPNAME=""
	GROUPID=""
	ACTION_OK=""
}

build_json(){
	json_obj="{
	\"ERSEndPoint\" :						\
		{							\
        	\"name\" :			\"$MAC\",		\
        	\"description\" :		\"$DESCRIPTION\",	\
        	\"mac\" :			\"$MAC\",		\
        	\"profileId\" :			\"$PROFILEID\",		\
        	\"staticProfileAssignment\" :	$STATIC_PROFILE_BOOL,	\
        	\"groupId\" :			\"$GROUPID\",		\
        	\"staticGroupAssignment\" :	$STATIC_GROUP_BOOL	\
		}							\
	}"
}

action_import(){
        get_group_by_id;
        get_profile_by_id;
	build_json;
        import_endpoint;
        script_status;
	reset_vars;
}

action_update(){
	# if 666 there is no entry for MAC on ISE, skip
	if get_mac_by_id != "666"; then
        	get_group_by_id;
        	get_profile_by_id;
		build_json;
        	update_endpoint;
        	script_status;
	fi
	reset_vars;
}

action_delete(){
        if get_mac_by_id != "666"; then
        	delete_endpoint;
        	script_status;
	fi
	reset_vars;
}

#MAIN FUNC

get_args $@;
test_connection;
check_csv;
#if $CSVFILE is set dont trigger single import functions
if [[ "$CSVFILE" != "" ]]; then
	for LINE in `cat $CSVFILE`; do
		parse_csv "$LINE"	
		if [[ "$ACTION" == "IMPORT" ]]; then
			action_import;
		elif [[ "$ACTION" == "UPDATE" ]]; then
			action_update
		elif [[ "$ACTION" == "DELETE" ]]; then
			action_delete
		fi
	done
else
	#single MAC functions
	if [[ "$ACTION" == "IMPORT" ]]; then
		action_import;
	elif [[ "$ACTION" == "UPDATE" ]]; then
		action_update;
	elif [[ "$ACTION" == "DELETE" ]]; then
		action_delete;
	fi
fi
# finally check the script run
if [[ "$PROBLEM_COUNT" -eq 0 ]]; then
	exit 0
else
	exit 1
fi
