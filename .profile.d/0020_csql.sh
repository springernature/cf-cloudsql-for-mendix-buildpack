#!/usr/bin/env bash
[ -z "$DEBUG" ] || set -x
set -euo pipefail

# See bin/finalize to check predefined vars
ROOT="/home/vcap"
export AUTH_ROOT="${ROOT}/auth"
export APP_ROOT="${ROOT}/app"

### Bindings
# SQL DB
export DB_BINDING_NAME="${DB_BINDING_NAME:-}"

# Variables exported, they are automatically filled from the service broker instances.
export MXRUNTIME_DatabaseHost=""
export MXRUNTIME_DatabaseName=""
export MXRUNTIME_DatabasePassword=""
export MXRUNTIME_DatabaseType=""
export MXRUNTIME_DatabaseUserName=""

export db_type=""
# export DB_USER="root"
# export DB_HOST=""
# export DB_PASS=""
export DB_PORT=""
# export DB_NAME="grafana"
export DB_CA_CERT=""
export DB_CLIENT_CERT=""
export DB_CLIENT_KEY=""
export DB_CERT_NAME=""
export DB_TLS=""

# exec process in bg
launch() {
    (
        echo "Launching pid=$$: '$@'"
        {
            exec $@  2>&1;
        }
    ) &
    pid=$!
    sleep 15
    if ! ps -p ${pid} >/dev/null 2>&1
    then
        echo
        echo "Error launching '$@'."
        rvalue=1
    else
        echo "Pid=${pid} running"
        rvalue=0
    fi
    return ${rvalue}
}

get_binding_service() {
    local binding_name="${1}"
    jq --arg b "${binding_name}" '.[][] | select(.binding_name == $b)' <<<"${VCAP_SERVICES}"
}

get_db_vcap_service() {
    local binding_name="${1}"

    if [[ -z "${binding_name}" ]] || [[ "${binding_name}" == "null" ]]
    then
        # searching for a sql service looking at the label...
        jq '[.[][] | select(.credentials.uri) | select(.credentials.uri | split(":")[0] == ("mysql","postgres"))] | first | select (.!=null)' <<<"${VCAP_SERVICES}"
    else
        get_binding_service "${binding_name}"
    fi
}

get_db_vcap_service_type() {
    local db="${1}"
    jq -r '.credentials.uri | split(":")[0]' <<<"${db}"
}

reset_env_DB() {
	MXRUNTIME_DatabaseHost=""
	MXRUNTIME_DatabaseName=""
	MXRUNTIME_DatabasePassword=""
	MXRUNTIME_DatabaseType=""
	MXRUNTIME_DatabaseUserName=""
}

set_env_DB() {
    local db="${1}"
    local uri=""

    db_type=$(get_db_vcap_service_type "${db}")
	echo "Found db type: ${db_type}"
	case $db_type in 
		mysql) MXRUNTIME_DatabaseType="MySQL" ;;
		postgres) MXRUNTIME_DatabaseType="PostgreSQL" ;;
    esac

    uri="${db_type}://"
    if ! MXRUNTIME_DatabaseUserName=$(jq -r -e '.credentials.Username' <<<"${db}")
    then
        MXRUNTIME_DatabaseUserName=$(jq -r -e '.credentials.uri |
            split("://")[1] | split(":")[0]' <<<"${db}") || MXRUNTIME_DatabaseUserName=''
    fi
    uri="${uri}${MXRUNTIME_DatabaseUserName}"
    if ! MXRUNTIME_DatabasePassword=$(jq -r -e '.credentials.Password' <<<"${db}")
    then
        MXRUNTIME_DatabasePassword=$(jq -r -e '.credentials.uri |
            split("://")[1] | split(":")[1] |
            split("@")[0]' <<<"${db}") || MXRUNTIME_DatabasePassword=''
    fi
    uri="${uri}:${MXRUNTIME_DatabasePassword}"
    if ! MXRUNTIME_DatabaseHost=$(jq -r -e '.credentials.host' <<<"${db}")
    then
        MXRUNTIME_DatabaseHost=$(jq -r -e '.credentials.uri |
            split("://")[1] | split(":")[1] |
            split("@")[1] |
            split("/")[0]' <<<"${db}") || MXRUNTIME_DatabaseHost=''
    fi
    uri="${uri}@${MXRUNTIME_DatabaseHost}"
    if [[ "${db_type}" == "mysql" ]]
    then
        DB_PORT="3306"
        uri="${uri}:${DB_PORT}"
        DB_TLS="false"
    elif [[ "${db_type}" == "postgres" ]]
    then
        DB_PORT="5432"
        uri="${uri}:${DB_PORT}"
        DB_TLS="disable"
    fi
    if ! MXRUNTIME_DatabaseName=$(jq -r -e '.credentials.database_name' <<<"${db}")
    then
        MXRUNTIME_DatabaseName=$(jq -r -e '.credentials.uri |
            split("://")[1] | split(":")[1] |
            split("@")[1] | split("/")[1] |
            split("?")[0]' <<<"${db}") || MXRUNTIME_DatabaseName=''
    fi
    uri="${uri}/${MXRUNTIME_DatabaseName}"
    # TLS
    mkdir -p ${AUTH_ROOT}
    if jq -r -e '.credentials.ClientCert' <<<"${db}" >/dev/null
    then
        jq -r '.credentials.CaCert' <<<"${db}" > "${AUTH_ROOT}/${MXRUNTIME_DatabaseName}-ca.crt"
        jq -r '.credentials.ClientCert' <<<"${db}" > "${AUTH_ROOT}/${MXRUNTIME_DatabaseName}-client.crt"
        jq -r '.credentials.ClientKey' <<<"${db}" > "${AUTH_ROOT}/${MXRUNTIME_DatabaseName}-client.key"
        DB_CA_CERT="${AUTH_ROOT}/${MXRUNTIME_DatabaseName}-ca.crt"
        DB_CLIENT_CERT="${AUTH_ROOT}/${MXRUNTIME_DatabaseName}-client.crt"
        DB_CLIENT_KEY="${AUTH_ROOT}/${MXRUNTIME_DatabaseName}-client.key"
        if instance=$(jq -r -e '.credentials.instance_name' <<<"${db}")
        then
            DB_CERT_NAME="${instance}"
            if project=$(jq -r -e '.credentials.ProjectId' <<<"${db}")
            then
                # Google GCP format
                DB_CERT_NAME="${project}:${instance}"
            fi
            [[ "${db_type}" == "mysql" ]] && DB_TLS="true"
            [[ "${db_type}" == "postgres" ]] && DB_TLS="verify-full"
        else
            DB_CERT_NAME=""
            [[ "${db_type}" == "mysql" ]] && DB_TLS="skip-verify"
            [[ "${db_type}" == "postgres" ]] && DB_TLS="require"
        fi
    fi
    echo "The URI: ${uri}"
}


# Given a DB from vcap services, defines the proxy files ${MXRUNTIME_DatabaseName}-auth.json and ${AUTH_ROOT}/${MXRUNTIME_DatabaseName}.proxy
set_DB_proxy() {
    local db="${1}"

    local proxy
    # If it is a google service, setup proxy by creating 2 files: auth.json and
    # cloudsql proxy configuration on ${MXRUNTIME_DatabaseName}.proxy
    # It will also overwrite the variables to point to localhost
    if jq -r -e '.tags | contains(["gcp"])' <<<"${db}" >/dev/null
    then
        jq -r '.credentials.PrivateKeyData' <<<"${db}" | base64 -d > "${AUTH_ROOT}/${MXRUNTIME_DatabaseName}-auth.json"
        proxy=$(jq -r '.credentials.ProjectId + ":" + .credentials.region + ":" + .credentials.instance_name' <<<"${db}")
        echo "${proxy}=tcp:${DB_PORT}" > "${AUTH_ROOT}/${MXRUNTIME_DatabaseName}.proxy"
        [[ "${db_type}" == "mysql" ]] && DB_TLS="false"
        [[ "${db_type}" == "postgres" ]] && DB_TLS="disable"
        MXRUNTIME_DatabaseHost="127.0.0.1"
    fi
    echo " DB URL: ${db_type}://${MXRUNTIME_DatabaseUserName}:${MXRUNTIME_DatabasePassword}@${MXRUNTIME_DatabaseHost}:${DB_PORT}/${MXRUNTIME_DatabaseName}"
}


# Sets all DB
set_sql_databases() {
    local db

    echo "Initializing DB settings from service instances..."
    reset_env_DB

    db=$(get_db_vcap_service "${DB_BINDING_NAME}")
	
    if [[ -n "${db}" ]]
    then
		echo "Setting the env_DB and DB_proxy..."
        set_env_DB "${db}" #>/dev/null
        set_DB_proxy "${db}" #>/dev/null
    fi
}

run_sql_proxies() {
    local instance
    local dbname

    if [[ -d ${AUTH_ROOT} ]]
    then
        for filename in $(find ${AUTH_ROOT} -name '*.proxy')
        do
            dbname=$(basename "${filename}" | sed -n 's/^\(.*\)\.proxy$/\1/p')
            instance=$(head "${filename}")
            echo "Launching local sql proxy for instance ${instance}..."
            launch cloud_sql_proxy -verbose \
                  -instances="${instance}" \
                  -credential_file="${AUTH_ROOT}/${dbname}-auth.json" \
                  -term_timeout=30s -ip_address_types=PRIVATE,PUBLIC
        done
    fi
}

################################################################################

set_sql_databases

# Run
run_sql_proxies
env | grep MXRUNTIME
# Set home dashboard only on the first instance
# [[ "${CF_INSTANCE_INDEX:-0}" == "0" ]] && set_homedashboard
# Go back to grafana_server and keep waiting, exit with its exit code.
# wait