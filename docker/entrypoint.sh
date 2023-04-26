#!/bin/bash

HELP_TEXT="

Arguments:
	run_arches: Default. Run the Arches server
	setup_arches: Delete any existing Arches database and set up a fresh one
	-h or help: Display help text
"

display_help() {
	echo "${HELP_TEXT}"
}



CUSTOM_SCRIPT_FOLDER=${CUSTOM_SCRIPT_FOLDER:-/docker/entrypoint}

if [[ -z ${ARCHES_PROJECT} ]]; then
	APP_FOLDER=${ARCHES_ROOT}
	PACKAGE_JSON_FOLDER=${ARCHES_ROOT}/arches/install

else
	APP_FOLDER=${WEB_ROOT}/${ARCHES_PROJECT}

	PACKAGE_JSON_FOLDER=${ARCHES_ROOT}/arches/install
	
fi

YARN_MODULES_FOLDER=${PACKAGE_JSON_FOLDER}/$(awk \
	-F '--install.modules-folder' '{print $2}' ${PACKAGE_JSON_FOLDER}/.yarnrc \
	| awk '{print $1}' \
	| tr -d $'\r' \
	| tr -d '"' \
	| sed -e "s/^\.\///g")

export DJANGO_PORT=${DJANGO_PORT:-8000}
STATIC_ROOT=${STATIC_ROOT:-/static_root}

cd_web_root() {
	cd ${WEB_ROOT}
	echo "Current work directory: ${WEB_ROOT}"
}
cd_arches_root() {
	cd ${ARCHES_ROOT}
	echo "Current work directory: ${ARCHES_ROOT}"
}
cd_app_folder() {
	cd ${APP_FOLDER}
	echo "Current work directory: ${APP_FOLDER}"
}
cd_yarn_folder() {
	cd ${PACKAGE_JSON_FOLDER}
	echo "Current work directory: ${PACKAGE_JSON_FOLDER}"
}
activate_virtualenv() {
	. ${WEB_ROOT}/ENV/bin/activate
}

init_arches() {
	if db_exists; then
		echo "Database ${PGDBNAME} already exists, skipping initialization."
		echo ""
	else
		echo "Database ${PGDBNAME} does not exists yet, starting setup..."
		setup_arches
	fi

	init_arches_project
}

setup_arches() {
	cd_arches_root

	echo "" && echo ""
	echo "*** Initializing database ***"
	echo ""
	echo "*** Any existing Arches database will be deleted ***"
	echo "" && echo ""

	echo "5" && sleep 1 && echo "4" && sleep 1 && echo "3" && sleep 1 && echo "2" && sleep 1 &&	echo "1" &&	sleep 1 && echo "0" && echo ""

	echo "Running: python manage.py setup_db --force"
	python manage.py setup_db --force

    echo "Running: Creating couchdb system databases"
    curl -X PUT ${COUCHDB_URL}/_users
    curl -X PUT ${COUCHDB_URL}/_global_changes
    curl -X PUT ${COUCHDB_URL}/_replicator
	
}

wait_for_db() {
	echo "Testing if database server is up..."
	while [[ ! ${return_code} == 0 ]]
	do
        psql --host=${PGHOST} --port=${PGPORT} --user=${PGUSERNAME} --dbname=postgres -c "select 1" >&/dev/null
		return_code=$?
		sleep 1
	done
	echo "Database server is up"

    echo "Testing if Elasticsearch is up..."
    while [[ ! ${return_code} == 0 ]]
    do
        curl -s "http://${ESHOST}:${ESPORT}/_cluster/health?wait_for_status=green&timeout=60s" >&/dev/null
        return_code=$?
        sleep 1
    done
    echo "Elasticsearch is up"
}

db_exists() {
	echo "Checking if database "${PGDBNAME}" exists..."
	count=`psql --host=${PGHOST} --port=${PGPORT} --user=${PGUSERNAME} --dbname=postgres -Atc "SELECT COUNT(*) FROM pg_catalog.pg_database WHERE datname='${PGDBNAME}'"`

	re='^[0-9]+$'
	if ! [[ ${count} =~ $re ]] ; then
	   echo "Error: Something went wrong when checking if database "${PGDBNAME}" exists..." >&2;
	   echo "Exiting..."
	   exit 1
	fi

	if [[ ${count} > 0 ]]; then
		return 0
	else
		return 1
	fi
}

set_dev_mode() {
	echo ""
	echo ""
	echo "----- SETTING DEV MODE -----"
	echo ""
	cd_arches_root
	python ${ARCHES_ROOT}/setup.py develop
}

init_yarn_components() {
	if [[ ! -d ${YARN_MODULES_FOLDER} ]] || [[ ! "$(ls ${YARN_MODULES_FOLDER})" ]]; then
		echo "Yarn modules do not exist, installing..."
		install_yarn_components
	fi
}

install_yarn_components() {
	echo ""
	echo ""
	echo "----- INSTALLING YARN COMPONENTS -----"
	echo ""
	cd_yarn_folder
	yarn install
}

init_arches_project() {
	if [[ ! -z ${ARCHES_PROJECT} ]]; then
		echo "Checking if Arches project "${ARCHES_PROJECT}" exists..."
		if [[ ! -d ${APP_FOLDER} ]] || [[ ! "$(ls ${APP_FOLDER})" ]]; then
			echo ""
			echo "----- Custom Arches project '${ARCHES_PROJECT}' does not exist. -----"
			echo "----- Creating '${ARCHES_PROJECT}'... -----"
			echo ""

			cd_web_root
			
			arches-project create ${ARCHES_PROJECT}

			exit_code=$?
			if [[ ${exit_code} != 0 ]]; then
				echo "Something went wrong when creating your Arches project: ${ARCHES_PROJECT}."
				echo "Exiting..."
				exit ${exit_code}
			fi

			copy_settings_local
		else
			echo "Custom Arches project '${ARCHES_PROJECT}' already exists."
		fi
	fi
}

copy_settings_local() {
	
	echo "Copying ${ARCHES_ROOT}/arches/settings_local.py to ${APP_FOLDER}/${ARCHES_PROJECT}/settings_local.py..."
	cp ${ARCHES_ROOT}/arches/settings_local.py ${APP_FOLDER}/${ARCHES_PROJECT}/settings_local.py
}

run_custom_scripts() {
	for file in ${CUSTOM_SCRIPT_FOLDER}/*; do
		if [[ -f ${file} ]]; then
			echo ""
			echo ""
			echo "----- RUNNING CUSTUM SCRIPT: ${file} -----"
			echo ""
			source ${file}
		fi
	done
}

run_django_server() {
	echo ""
	echo ""
	echo "----- *** RUNNING DJANGO DEVELOPMENT SERVER *** -----"
	echo ""
	cd_app_folder
	if [[ ${DJANGO_REMOTE_DEBUG} != "True" ]]; then
	    echo "Running Django with livereload."
		exec python manage.py runserver 0.0.0.0:${DJANGO_PORT}
	else
        echo "Running Django with options --noreload --nothreading for remote debugging."
		exec python manage.py runserver --noreload --nothreading 0.0.0.0:${DJANGO_PORT}
	fi
}

run_arches() {

	init_arches

	init_yarn_components

	if [[ "${DJANGO_MODE}" == "DEV" ]]; then
		set_dev_mode
	fi

	run_custom_scripts

	if [[ "${DJANGO_MODE}" == "DEV" ]]; then
		run_django_server
	fi
}


activate_virtualenv

if [[ $#  -eq 0 ]]; then
	run_arches
fi


echo "Full command: $@"
while [[ $# -gt 0 ]]
do
	key="$1"
	echo "Command: ${key}"

	case ${key} in
		run_arches)
			wait_for_db
			run_arches
		;;
		setup_arches)
			wait_for_db
			setup_arches
		;;
	
		install_yarn_components)
			install_yarn_components
		;;
		help|-h)
			display_help
		;;
		*)
            cd_app_folder
			"$@"
			exit 0
		;;
	esac
	shift 
done
