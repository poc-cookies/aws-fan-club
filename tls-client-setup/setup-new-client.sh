#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status.
set -e


# Prerequisites:
#
# 1. keytool (usually comes along with Java)
# 2. openssl
# 3. AWS cli
# 4. Perl
# 5. mktemp
# 6. All the prerequisites of issue-certificate.sh script
#
# Execution Plan:
#
# 1. Arguments check
# 2. Initialisation
# 3. Create a Trust Store (TS)
# 4. Create a Private Key (PK) & store it in a new Key Store (KS)
# 5. Create a Certificate Signin Request (CSR) with the PK
# 6. Sign the CSR with the CA & issue a Certificate (C)
# 7. Add the signed Certificate to the Key Store
# 8. Store the password in SM
# 9. Upload the TS and KS to S3
# 10. Clean up


# 1. Arguments check

print_usage() {
    cat <<USAGEMSG
$0: error: the following arguments are required: client-name
usage: $0 client-name
example: $0 "Client 1 Name"
USAGEMSG
}

if [ $# -ne 1 ]; then
    print_usage
    exit 1
fi


# 2. Initialisation

readonly client_name=$1
readonly client_id=$(echo ${client_name} | tr ' ' '_' | tr '[:upper:]' '[:lower:]')
readonly client_alias=$client_id

readonly tmp_dir=$(mktemp -d)

readonly trust_store_name=kafka.client.truststore.jks
readonly trust_store_path=${tmp_dir}/${trust_store_name}
readonly key_store_name=kafka.client.keystore.jks
readonly key_store_path=${tmp_dir}/${key_store_name}
readonly store_password=$(openssl rand -base64 32)

readonly csr_path=${tmp_dir}/client-csr
readonly csr_sigalg='SHA256WITHRSA'
readonly cert_path=${tmp_dir}/signed-certificate-from-acm

readonly s3_bucket=''
readonly s3_client_path="s3://${s3_bucket}/${client_id}"
readonly s3_stores_path="${s3_client_path}/stores"
readonly s3_trust_store_path=${s3_stores_path}/${trust_store_name}
readonly s3_key_store_path=${s3_stores_path}/${key_store_name}

readonly sm_password_name="msk-client/${client_id}.password"


# 3. Create a Trust Store (TS)
echo 'Creating a Trust Store...'
cp ${JAVA_HOME}/lib/security/cacerts ${trust_store_path}
echo 'Trust store created successfully!'


# 4. Create a Private Key (PK) & store it in a new Key Store (KS)
echo 'Creating a Private Key (PK) & storing it in the Key Store (KS)...'
keytool -genkey -keystore ${key_store_path} -validity 300 -storepass ${store_password} -keypass ${store_password} -dname "CN=${client_name}" -alias "${client_alias}" -storetype pkcs12 -keyalg RSA -keysize 2048
echo 'PK created & stored in KS successfully!'


# 5. Create a Certificate Signin Request (CSR) with the PK
echo 'Creating a Certificate Signin Request (CSR) with the PK...'
keytool -keystore ${key_store_path} -certreq -file ${csr_path} -sigalg ${csr_sigalg} -alias "${client_alias}" -storepass ${store_password} -keypass ${store_password}
perl -pi -e 's/BEGIN NEW CERTIFICATE REQUEST/BEGIN CERTIFICATE REQUEST/g' ${csr_path}
perl -pi -e 's/END NEW CERTIFICATE REQUEST/END CERTIFICATE REQUEST/g' ${csr_path}
echo 'CSR created successfully!'


# 6. Sign the CSR with the CA & issue a Certificate (C)
echo 'Run issue-certificate script and obtain the issued certificate...'
./issue-certificate.sh "${client_name}" ${csr_path} ${csr_sigalg} ${cert_path}
echo 'issue-certificate finished successfully!'


# 7. Add the signed Certificate to the Key Store
echo 'Adding the signed Certificate to the Key Store'
keytool -keystore ${key_store_path} -import -file ${cert_path} -alias "${client_alias}" -storepass ${store_password} -keypass ${store_password} -noprompt
echo 'Signed Certificate added to the Key Store successfully!'


# 8. Store the password in SM
echo "Uploading the store password to Secrets Manager..."
aws secretsmanager create-secret --name ${sm_password_name} --secret-string ${store_password}
echo "Store password uploaded to Secrets Manager successfully!"


# 9. Upload the TS and KS to S3
echo "Uploading the TS and KS to S3..."
aws s3 cp ${trust_store_path} ${s3_trust_store_path}
aws s3 cp ${key_store_path} ${s3_key_store_path}
echo "TS and KS uploaded to S3 successfully!"


# 10. Clean up

echo "Cleaning up..."

clean_up() {
    rm -rf ${tmp_dir}
}

trap clean_up EXIT

echo 'Setup of a new client has been DONE!'
echo "Get the trust and key stores from the S3 bucket: ${s3_stores_path}"
echo "Get the store password from the SM secret: ${sm_password_name}"
