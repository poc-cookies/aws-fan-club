#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status.
set -e


# Prerequisites:
#
# 1. AWS cli
# 2. jq
# 3. mktemp
#
# Execution Plan:
#
# 1. Arguments check
# 2. Initialisation
# 3. Sign the CSR with the CA & issue a Certificate (C)
# 4. Upload meta in S3 (timestamp / client id / client name / cert ARN)
# 5. Upload the CSR to S3
# 6. Fetch the Signed Certificate
# 7. Write the signed certificate to the output file
# 8. Upload the signed cert to S3
# 9. Clean up

# 1. Arguments check

print_usage() {
    cat <<USAGEMSG
$0: error: the following arguments are required: client-name csr-path sigalg cert-out-path
usage: $0 client-name csr-path sigalg cert-path
example: $0 "Client 1 Name" "\$HOME/example/csr" "SHA256WITHRSA" "\$HOME/example/certificate"
USAGEMSG
}

if [ $# -ne 4 ]; then
    print_usage
    exit 1
fi


# 2. Initialisation

readonly client_name=$1
readonly client_id=$(echo ${client_name} | tr ' ' '_' | tr '[:upper:]' '[:lower:]')
readonly csr_path=$2
readonly sigalg=$3
readonly cert_out_path=$4

readonly s3_bucket=''
readonly ca_arn=''

readonly tmp_dir=$(mktemp -d)
readonly meta_path=${tmp_dir}/meta

readonly s3_client_path="s3://${s3_bucket}/${client_id}"
readonly s3_meta_path="${s3_client_path}/meta"
readonly s3_csr_path="${s3_client_path}/csr"
readonly s3_cert_path="${s3_client_path}/certificate"

echo "Issuing a certificate for ClientID: ${client_id}"


# 3. Sign the CSR with the CA & issue a Certificate (C)
echo 'Issuing a Certificate...'
signing_response=$(aws acm-pca issue-certificate --certificate-authority-arn ${ca_arn} --csr fileb://${csr_path} --signing-algorithm ${sigalg} --validity Value=300,Type="DAYS")
cert_arn=$(echo "${signing_response}" | jq -r .CertificateArn)
echo 'Certificate issued successfully!'


# 4. Upload meta in S3 (timestamp / client id / client name / cert ARN)
echo "Uploading meta information (client id & cert ARN) to S3..."
echo "CreatedAt: $(date -u)" > ${meta_path}
echo "ClientId: ${client_id}" >> ${meta_path}
echo "ClientName: ${client_name}" >> ${meta_path}
echo "CertARN: ${cert_arn}" >> ${meta_path}
aws s3 cp ${meta_path} ${s3_meta_path}
echo "Meta information uploaded to S3 successfully!"


# 5. Upload the CSR to S3
echo "Uploading CSR to S3..."
aws s3 cp ${csr_path} ${s3_csr_path}
echo "CSR uploaded to S3 successfully!"


# 6. Fetch the Signed Certificate
echo 'Fetching the signed certificate...'
cert_resp=$(aws acm-pca get-certificate --certificate-authority-arn ${ca_arn} --certificate-arn ${cert_arn})
echo 'Signed certificate fetched successfully!'


# 7. Write the signed certificate to the output file
echo 'Writing the signed cerfiticate to a file...'
echo "${cert_resp}" | jq -r .Certificate > ${cert_out_path}
echo "${cert_resp}" | jq -r .CertificateChain >> ${cert_out_path}
echo 'Signed cerfiticate written to a file successfully!'


# 8. Upload the signed cert to S3
echo "Uploading the signed certificate to S3..."
aws s3 cp ${cert_out_path} ${s3_cert_path}
echo "Signed certificate uploaded to S3 successfully!"


# 9. Clean up

echo "Cleaning up..."

clean_up() {
    rm -rf ${tmp_dir}
}

trap clean_up EXIT

echo 'Certificate issuance has been DONE!'
