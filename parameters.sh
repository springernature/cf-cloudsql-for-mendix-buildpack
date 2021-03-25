# Variables, this file is designed to be sourced by supply

# default versions
CLOUDSQL_PROXY_VERSION="${CLOUDSQL_PROXY_VERSION:-1.13}"

# Download URLS
CLOUDSQL_PROXY_DOWNLOAD_URL="https://storage.googleapis.com/cloudsql-proxy/v${CLOUDSQL_PROXY_VERSION}/cloud_sql_proxy.linux.amd64"

# dependencies paths
SQLPROXY_DIR="${DEPS_DIR}/${DEPS_IDX}/cloud_sql_proxy"
