#!/bin/bash
set -euo pipefail

# # # # # # # # # # # # # # # # # # # #
SP_TENANT=72f988bf-86f1-41af-91ab-2d7cd011db47
SP_APPID=30f76dd2-a2d9-4abb-acad-c298b8ac04c4
SP_PWD=7Fp7Q~tdXCjP1QjFmLzSlKiLqlZAR5ZGOFNBJ
RESOURCE_GROUP_NAME=dv-ebdev
STORAGE_ACCOUNT_NAME=ebdevcvmfs
CONTAINER_NAME=common
KEYVAULT_NAME=ebdevkv
CVMFS_USER=hpcadmin
SIGNATURE_EXPIRATION_DAYS=365
# # # # # # # # # # # # # # # # # # # #

CVMFS_REPO_NAME=${CONTAINER_NAME}.azure
SECRET_NAME=${STORAGE_ACCOUNT_NAME}-${CONTAINER_NAME}

step_info () {
    printf '\e[33m>>> %s\e[0m\n' "$@"
}

error () {
    printf '\e[31m!!!ERROR!!! %s\e[0m\n' "$@"
    exit 1
}

# Install jq if not already installed
if ! command -v jq &> /dev/null; then
    step_info 'Installing jq'
    sudo yum install -y epel-release
    sudo yum install -y jq
fi

# Install Azure CLI if not already installed
if ! command -v az &> /dev/null; then
    step_info 'Installing Azure CLI'
    sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
    cat << EOF | sed 's/^ *//' | sudo tee /etc/yum.repos.d/azure-cli.repo > /dev/null
    [azure-cli]
    name=Azure CLI
    baseurl=https://packages.microsoft.com/yumrepos/azure-cli
    enabled=1
    gpgcheck=1
    gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF
    sudo yum install -y azure-cli
else
    step_info 'Azure CLI already installed'
fi

# Sign in Azure CLI with service principal
step_info 'Azure CLI login'
az login --service-principal --tenant ${SP_TENANT} --username ${SP_APPID} --password ${SP_PWD}

# Create storage account
# It is paramount to disable HTTPS only since CVMFS currently supports only HTTP
# Only Standard SKU supports public access containers
step_info "Creating storage account: ${STORAGE_ACCOUNT_NAME}"
az storage account create --name ${STORAGE_ACCOUNT_NAME} --resource-group ${RESOURCE_GROUP_NAME} \
                          --sku Standard_LRS --https-only false --min-tls-version TLS1_2

# Create storage container if not already present
# If present, check if it contains the CVMFS repository blobs
CONTAINERS_LIST=$(az storage container list --account-name ${STORAGE_ACCOUNT_NAME} --auth-mode login | jq -r '.[].name')
if [[ ! ${CONTAINERS_LIST} =~ ${CONTAINER_NAME} ]]; then
    step_info "Creating storage container: ${CONTAINER_NAME}"
    az storage container create --account-name ${STORAGE_ACCOUNT_NAME} --name ${CONTAINER_NAME} \
                                --public-access container --auth-mode login
    REPO_BLOBS_EXIST=False
else
    step_info 'Container is already present'
    step_info 'Checking for repository blobs'
    BLOBS_LIST=$(az storage blob list --account-name ${STORAGE_ACCOUNT_NAME} --container-name ${CONTAINER_NAME} | jq -r '.[].name')
    if [[ ${BLOBS_LIST} =~ ${CVMFS_REPO_NAME}/.cvmfswhitelist ]]; then
        REPO_BLOBS_EXIST=True
    else
        REPO_BLOBS_EXIST=False
    fi
fi

# Create keyvault if not already present
# If present, check if masterkey secret is already stored in it
KEYVAULTS_LIST=$(az keyvault list --resource-group ${RESOURCE_GROUP_NAME} | jq -r '.[].name')
if [[ ! ${KEYVAULTS_LIST} =~ ${KEYVAULT_NAME} ]]; then
    step_info "Creating keyvault: ${KEYVAULT_NAME}"
    az keyvault create --resource-group ${RESOURCE_GROUP_NAME} --name ${KEYVAULT_NAME}
    MASTERKEY_EXIST=False
else
    step_info "Keyvault ${KEYVAULT_NAME} already exists"
    step_info "Checking if repository master key is in key vault"
    SECRETS_LIST=$(az keyvault secret list --vault-name ${KEYVAULT_NAME} | jq -r '.[].name')
    if [[ ${SECRETS_LIST} =~ ${SECRET_NAME}-masterkey ]]; then
        MASTERKEY_EXIST=True
    else
        MASTERKEY_EXIST=False
    fi
fi

# Generate CVMFS repository configuration
step_info 'Generating CVMFS repository configuration'
BLOB_KEY=$(az storage account keys list -g ${RESOURCE_GROUP_NAME} -n ${STORAGE_ACCOUNT_NAME} \
           --query "[?keyName=='key2'].value" -o tsv)
sudo tee /etc/cvmfs/${CVMFS_REPO_NAME}.conf > /dev/null << EOF
CVMFS_S3_HOST=${STORAGE_ACCOUNT_NAME}.blob.core.windows.net
CVMFS_S3_ACCESS_KEY=${STORAGE_ACCOUNT_NAME}
CVMFS_S3_SECRET_KEY=${BLOB_KEY}
CVMFS_S3_BUCKET=${CONTAINER_NAME}
CVMFS_S3_DNS_BUCKETS=false
CVMFS_S3_FLAVOR=azure
EOF

# Create CVMFS file system only if master key and blobs are already present
# Otherwise try to import the existing repository
if [[ ${MASTERKEY_EXIST} == 'False' && ${REPO_BLOBS_EXIST} == 'False' ]]; then
    # Check if the repository is already initialized in the server. It such case skip for idempotence
    if [[ $(cvmfs_server list) =~ ${CVMFS_REPO_NAME} ]]; then
        step_info "CVMFS repository ${CVMFS_REPO_NAME} already initialized"
    else
        step_info "Creating CVMFS repository: ${CVMFS_REPO_NAME}"
        sudo cvmfs_server mkfs -s /etc/cvmfs/${CVMFS_REPO_NAME}.conf \
                               -w http://${STORAGE_ACCOUNT_NAME}.blob.core.windows.net/${CONTAINER_NAME} \
                               -o ${CVMFS_USER} ${CVMFS_REPO_NAME}

        # Upload repository masterkey to key vault secret
        step_info "Uploading master key to key vault: ${KEYVAULT_NAME}"
        az keyvault secret set -n ${SECRET_NAME}-masterkey --vault-name ${KEYVAULT_NAME} \
                       --value "$(cat /etc/cvmfs/keys/${CVMFS_REPO_NAME}.masterkey)"

        # Upload certificate and key to key vault secrets
        step_info "Uploading CVMFS repository certificate, private and public key to key vault: ${KEYVAULT_NAME}"
        az keyvault secret set -n ${SECRET_NAME}-cert --vault-name ${KEYVAULT_NAME} \
                               --value "$(cat /etc/cvmfs/keys/${CVMFS_REPO_NAME}.crt)"
        az keyvault secret set -n ${SECRET_NAME}-privatekey --vault-name ${KEYVAULT_NAME} \
                               --value "$(cat /etc/cvmfs/keys/${CVMFS_REPO_NAME}.key)"
        az keyvault secret set -n ${SECRET_NAME}-publickey --vault-name ${KEYVAULT_NAME} \
                               --value "$(cat /etc/cvmfs/keys/${CVMFS_REPO_NAME}.pub)"

        # Add CVMFS repository public key and client configuration to blob
        step_info 'Uploading CVMFS repository public key to blob'
        az storage blob upload --account-name ${STORAGE_ACCOUNT_NAME} --container-name ${CONTAINER_NAME} \
                               --name ${CVMFS_REPO_NAME}.pub \
                               --file /etc/cvmfs/keys/${CVMFS_REPO_NAME}.pub \
                               --auth-mode key

        step_info 'Generating CVMFS client configuration file'
        cat << EOF | sed 's/^ *//' > ${CVMFS_REPO_NAME}.conf
        CVMFS_SERVER_URL=http://${STORAGE_ACCOUNT_NAME}.blob.core.windows.net/${CONTAINER_NAME}/${CVMFS_REPO_NAME}
        CVMFS_PUBLIC_KEY=/etc/cvmfs/keys/${CVMFS_REPO_NAME}.pub
        CVMFS_HTTP_PROXY=DIRECT
EOF

        step_info 'Uploading CVMFS client configuration file to blob'
        az storage blob upload --account-name ${STORAGE_ACCOUNT_NAME} --container-name ${CONTAINER_NAME} \
                               --name ${CVMFS_REPO_NAME}.conf \
                               --file ./${CVMFS_REPO_NAME}.conf \
                               --auth-mode key
        rm -f ${CVMFS_REPO_NAME}.conf
    fi

elif [[ ${MASTERKEY_EXIST} == 'True' && ${REPO_BLOBS_EXIST} == 'True' ]]; then
    step_info "Downloading CVMFS repository keys from key vault"
    az keyvault secret download --name ${SECRET_NAME}-masterkey --file ${CVMFS_REPO_NAME}.masterkey --vault-name ${KEYVAULT_NAME}
    az keyvault secret download --name ${SECRET_NAME}-privatekey --file ${CVMFS_REPO_NAME}.key --vault-name ${KEYVAULT_NAME}
    az keyvault secret download --name ${SECRET_NAME}-publickey --file ${CVMFS_REPO_NAME}.pub --vault-name ${KEYVAULT_NAME}
    az keyvault secret download --name ${SECRET_NAME}-cert --file ${CVMFS_REPO_NAME}.crt --vault-name ${KEYVAULT_NAME}

    sudo mv ${CVMFS_REPO_NAME}.{masterkey,key,pub,crt} /etc/cvmfs/keys
    sudo chown root:root /etc/cvmfs/keys/${CVMFS_REPO_NAME}.{masterkey,key,pub,crt}

    step_info "Importing existing CVMFS repository"
    sudo cvmfs_server import -w http://${STORAGE_ACCOUNT_NAME}.blob.core.windows.net/${CONTAINER_NAME}/${CVMFS_REPO_NAME} \
                             -k /etc/cvmfs/keys \
                             -o ${CVMFS_USER} \
                             -p \
                             -r \
                             -u "S3,/var/spool/cvmfs/${CVMFS_REPO_NAME}/tmp,${CVMFS_REPO_NAME}@/etc/cvmfs/${CVMFS_REPO_NAME}.conf" \
                             ${CVMFS_REPO_NAME}

elif [[ ${MASTERKEY_EXIST} == 'True' && ${REPO_BLOBS_EXIST} == 'False' ]]; then
    error "Master key exists but no corresponding blobs found in container: ${CONTAINER_NAME}"

elif [[ ${MASTERKEY_EXIST} == 'False' && ${REPO_BLOBS_EXIST} == 'True' ]]; then
    error "Repository blobs found but no corresponding master key stored in key vault: ${KEYVAULT_NAME}"
fi

# Enable automatic catalog management
step_info 'Enabling automatic CVMFS catalog management'
sudo sed -i 's/CVMFS_AUTOCATALOGS=false/CVMFS_AUTOCATALOGS=true/g' \
            /etc/cvmfs/repositories.d/${CVMFS_REPO_NAME}/server.conf
