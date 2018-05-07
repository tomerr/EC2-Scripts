#!/bin/bash

instance_type="c5.large"

function spin {
        REWRITE="\e[25D\e[1A\e[K"
        spinner=( "|" "/" "-" "\\" )
        for i in ${spinner[@]}; do
                c=$i
                sleep 1
                echo -e "${REWRITE}$c"
        done
}

if [[ -z $1 ]] || [[ -z $2 ]] || [[ -z $3 ]]; then
        echo "Usage: $0 [CustomerName] [eu-west-1 | eu-west-2 | us-east-1] [PROD | UAT] [gp2]"
        exit 1
fi
customerNameArg=$1
region=$2
isType=$3
isGP2=$4

if [[ "$isType" != "UAT" ]] && [[ "$isType" != "PROD" ]]; then
        echo "Usage: $0 [CustomerName] [eu-west-1 | eu-west-2 | us-east-1] [PROD | UAT] [gp2]"
        exit 1
fi

if [[ "$region" != "eu-west-1" ]] && [[ "$region" != "eu-west-2" ]] && [[ "$region" != "us-east-1" ]]; then
        echo "Usage: $0 [CustomerName] [eu-west-1 | eu-west-2 | us-east-1] [PROD | UAT] [gp2]"
        exit 1
fi

declare vpc_id
declare subnet_id
declare ami_id
declare key
declare additional_sg
declare regionName

customerName=`echo $customerNameArg | tr '[:lower:]' '[:upper:]'`

case "$2" in
        eu-west-1)
                
                                if [[ "$isType" == "PROD" ]]; then
                                        subnet_id="subnet-e0349388"
                                        additional_sgs="sg-ae6f2cc8 sg-b3818fd1"
                                else 
                                        subnet_id="subnet-0ff0db7b"
                                        additional_sgs="sg-e3cf9185 sg-c69ea5bf"
                                fi
                                ami_id="ami-d9fbaea0"
                                key="support"
                                vpc_id="vpc-08ba6360"
                                regionName="IR"
            ;;
        eu-west-2)

                                if [[ "$isType" == "PROD" ]]; then
                                        subnet_id="subnet-4a011832"
                                        additional_sgs="sg-885c9ce1 sg-c01645a9"
                                else
                                        subnet_id="subnet-0ff0db7b"
                                        additional_sgs="sg-08573861"
                                fi
                                ami_id="ami-5cd2343b"
                                key="support-uk"
                                vpc_id="vpc-17d0247e"
                                regionName="UK"
            ;;
        us-east-1)
                
                                if [[ "$isType" == "PROD" ]]; then
                                        subnet_id="subnet-0c22f227"
                                        additional_sgs="sg-e0c9ce91 sg-e0c9ce91"
                                else
                                        subnet_id="subnet-3622f21d"
                                        additional_sgs="sg-e0c9ce91 sg-30c0f34e"
                                fi
                                ami_id="ami-28f52055"
                                key="support-us"
                                vpc_id="vpc-b6f099d3"
                                regionName="US"
            ;;
        *)
                                exit 1
esac

instanceName="$isType-$customerName-$regionName"
instance_tags="{Key=Backup,Value=Daily},{Key=Name,Value=$instanceName},{Key=Client,Value=$customerName},{Key=Type,Value=$isType},{Key=Service,Value=$customerName.$isType}"

#Creating security group

declare sgs

if [[ "$isType" == "PROD" ]]; then
                # add specific new SG for customer
        dedicatedSG="SG-$isType-$customerName-$regionName"
        aws ec2 --region $region create-security-group --group-name $dedicatedSG --description $dedicatedSG --vpc-id $vpc_id | grep GroupId | awk '{print $2}'| tr -d \"
        dedicatedSG_id=`aws ec2 --region $region describe-security-groups --filters Name=group-name,Values="$dedicatedSG" --query 'SecurityGroups[*].{ID:GroupId}' | grep "ID" | awk '{print $2}' | tr -d \"`
        sgs="$dedicatedSG_id $additional_sgs"
        # aws ec2 authorize-security-group-ingress --region $region --group-name $dedicatedSG --protocol all --cidr 192.168.255.0/25
else
        sgs="$additional_sgs"
fi

declare new_id
declare eip
declare DeviceNameArgs

#set /dev/xvdf SSD or Magnetic, Script default is standard.
xvdf_snapId=`aws ec2 describe-images --region  $region --image-ids $ami_id | jq '.Images[0].BlockDeviceMappings[1].Ebs.SnapshotId' | tr -d \"`
if [ "$isGP2" == "gp2" ]; then
        DeviceNameArgs='DeviceName=/dev/xvdf,Ebs={SnapshotId='$xvdf_snapId',VolumeType=gp2}'
else
        DeviceNameArgs='DeviceName=/dev/xvdf,Ebs={SnapshotId='$xvdf_snapId',VolumeType=standard}'
fi
echo $DeviceNameArgs

instance=$(aws ec2 run-instances --region $region --iam-instance-profile Name=goCloud_DevOps_Central --disable-api-termination --image-id $ami_id --block-device-mappings ${DeviceNameArgs} --count 1 --instance-type $instance_type --key-name $key --security-group-ids $sgs --subnet-id $subnet_id --user-data file://userdata.txt --tag-specifications 'ResourceType=instance,Tags=['$instance_tags']' 'ResourceType=volume,Tags=['$instance_tags']')
if [ $? != 0 ]; then
    echo -e "\e[91mfailed to create instance.\e[39m"
        exit 1
else
        new_id=$(echo $instance | egrep -o "InstanceId.*" | egrep -o '^[^,]+' | awk '{print $2}' | cut -d\" -f2)
        echo "Creating Instance $new_id"
fi

echo "Waiting for new instance launch, please wait."
#Waiting until the instance is running and displaying its status
until [[ "$status" = *"running"* ]]; do
        spin
        status=$(aws ec2 describe-instance-status --region $region --instance-ids $new_id)
        spin ; spin ; spin ; spin
done

echo Requesting new EIP.
eip_alloc=$(aws ec2 --region $region allocate-address --domain vpc | grep "AllocationId" | awk '{print $2}' | tr -d \" | tr -d \,)
eip=$(aws ec2 --region $region describe-addresses --allocation-ids $eip_alloc | grep "PublicIp" | awk '{print $2}' | tr -d \" | tr -d \,)
echo Attaching new EIP: $eip to $new_id
aws ec2 associate-address --region $region --instance-id $new_id --allocation-id $eip_alloc
[[ $? == 0 ]] && echo "EIP Attached Succesffully"

ip=$(aws ec2 describe-instances --region $region --instance-ids $new_id | grep PrivateIpAddress | head -1)
if [ $? == 0 ]; then
        echo -e "\e[92mFinished sucessfully.\e[39m"
fi
echo "$instance" > "$new_id".log
echo "New Instance ID: $new_id"
echo "Instance name: $instanceName"
intIP=`echo $ip | awk '{print $2}' | cut -d"," -f1 | tr -d \"`
echo "New Instance IP addresses: $intIP $eip"
echo "adding route53 (DNS) records"

customerName_lc=`echo $customerName | tr '[:upper:]' '[:lower:]'`

if [[ "$isType" != "PROD" ]]; then
customerName_lc=`echo $customerName-$isType | tr '[:upper:]' '[:lower:]'`
fi 

cat > DNSadd.json <<EOF
{
    "Comment": "Update record to reflect new IP address",
    "Changes": [
        {
            "Action": "UPSERT",
            "ResourceRecordSet": {
                "Name": "$customerName_lc.tradair.com.",
                "Type": "A",
                "TTL": 300,
                "ResourceRecords": [
                    {
                        "Value": "$eip"
                    }
                ]
            }
        },
        {
            "Action": "UPSERT",
            "ResourceRecordSet": {
                "Name": "$customerName_lc-p.tradair.com.",
                "Type": "A",
                "TTL": 300,
                "ResourceRecords": [
                    {
                        "Value": "$intIP"
                    }
                ]
            }
        }
    ]
}
EOF

aws route53 change-resource-record-sets --hosted-zone-id Z295CSUXYNZ5HQ --change-batch file://DNSadd.json
if [ $? == 0 ]; then
        echo -e "\e[92mDNS added sucessfully.\e[39m"
                echo "Private DNS: $customerName_lc-p.tradair.com"
                echo "Public DNS: $customerName_lc.tradair.com."
else 
                echo -e "\e[91mfailed to create DNS entries.\e[39m"
fi
rm -f DNSadd.json

echo "More instance details in: "$new_id".log"
