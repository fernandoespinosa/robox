#!/bin/bash

# On MacOS the following utilities are needed.
# brew install --with-default-names jq gnu-sed coreutils

# Handle self referencing, sourcing etc.
if [[ $0 != $BASH_SOURCE ]]; then
  export CMD=$BASH_SOURCE
else
  export CMD=$0
fi

# Ensure a consistent working directory so relative paths work.
pushd `dirname $CMD` > /dev/null
BASE=`pwd -P`
popd > /dev/null

if [ $# != 1 ]; then
  tput setaf 1; printf "\n\n  Usage:\n    $0 FILENAME\n\n\n"; tput sgr0
  exit 1
fi

if [ ! -f "$1" ]; then
  tput setaf 1; printf "\n\nThe $1 file does not exist.\n\n\n"; tput sgr0
  exit 1
fi

if [ -f /opt/vagrant/embedded/bin/curl ]; then
  export CURL="/opt/vagrant/embedded/bin/curl"
else
  export CURL="curl"
fi

if [ -f /opt/vagrant/embedded/lib64/libssl.so ] && [ -z LD_PRELOAD ]; then
  export LD_PRELOAD="/opt/vagrant/embedded/lib64/libssl.so"
elif [ -f /opt/vagrant/embedded/lib64/libssl.so ]; then
  export LD_PRELOAD="/opt/vagrant/embedded/lib64/libssl.so:$LD_PRELOAD"
fi

if [ -f /opt/vagrant/embedded/lib64/libcrypto.so ] && [ -z LD_PRELOAD ]; then
  export LD_PRELOAD="/opt/vagrant/embedded/lib64/libcrypto.so"
elif [ -f /opt/vagrant/embedded/lib64/libcrypto.so ]; then
  export LD_PRELOAD="/opt/vagrant/embedded/lib64/libcrypto.so:$LD_PRELOAD"
fi

export LD_LIBRARY_PATH="/opt/vagrant/embedded/bin/lib/:/opt/vagrant/embedded/lib64/"

if [[ `uname` == "Darwin" ]]; then
  export CURL_CA_BUNDLE=/opt/vagrant/embedded/cacert.pem
fi

# The jq tool is needed to parse JSON responses.
if [ ! -f /usr/bin/jq ] && [ ! -f /usr/local/bin/jq ]; then
  tput setaf 1; printf "\n\nThe 'jq' utility is not installed.\n\n\n"; tput sgr0
  exit 1
fi

# Ensure the credentials file is available.
if [ -f $BASE/../../.credentialsrc ]; then
  source $BASE/../../.credentialsrc
else
  tput setaf 1; printf "\nError. The credentials file is missing.\n\n"; tput sgr0
  exit 2
fi

if [ -z ${VAGRANT_CLOUD_TOKEN} ]; then
  tput setaf 1; printf "\nError. The vagrant cloud token is missing. Add it to the credentials file.\n\n"; tput sgr0
  exit 2
fi

FILENAME=`basename "$1"`
FILEPATH=`realpath "$1"`

ORG=`echo "$FILENAME" | sed "s/\([a-z]*\)[\-]*\([a-z0-9-]*\)-\(hyperv\|vmware\|libvirt\|docker\|parallels\|virtualbox\)-\([0-9\.]*\).box/\1/g"`
BOX=`echo "$FILENAME" | sed "s/\([a-z]*\)[-]*\([a-z0-9-]*\)-\(hyperv\|vmware\|libvirt\|docker\|parallels\|virtualbox\)-\([0-9\.]*\).box/\2/g"`
PROVIDER=`echo "$FILENAME" | sed "s/\([a-z]*\)[-]*\([a-z0-9-]*\)-\(hyperv\|vmware\|libvirt\|docker\|parallels\|virtualbox\)-\([0-9\.]*\).box/\3/g"`
VERSION=`echo "$FILENAME" | sed "s/\([a-z]*\)[-]*\([a-z0-9-]*\)-\(hyperv\|vmware\|libvirt\|docker\|parallels\|virtualbox\)-\([0-9\.]*\).box/\4/g"`

# Handle the Lavabit boxes.
if [ "$ORG" == "magma" ]; then
  ORG="lavabit"
  if [ "$BOX" == "" ]; then
    BOX="magma"
  else
    BOX="magma-$BOX"
  fi

  # Specialized magma box name mappings.
  [ "$BOX" == "magma-alpine36" ] && BOX="magma-alpine"
  [ "$BOX" == "magma-debian8" ] && BOX="magma-debian"
  [ "$BOX" == "magma-fedora27" ] && BOX="magma-fedora"
  [ "$BOX" == "magma-freebsd11" ] && BOX="magma-freebsd"
  [ "$BOX" == "magma-openbsd6" ] && BOX="magma-openbsd"

fi

# Handle the Lineage boxes.
if [ "$ORG" == "lineage" ] || [ "$ORG" == "lineageos" ]; then
  if [ "$BOX" == "" ]; then
    BOX="lineage"
  else
    BOX="lineage-$BOX"
  fi
fi

# Handle the Vmware provider type.
if [ "$PROVIDER" == "vmware" ]; then
  PROVIDER="vmware_desktop"
fi

# Verify the values were all parsed properly.
if [ "$ORG" == "" ]; then
  tput setaf 1; printf "\n\nThe organization couldn't be parsed from the file name.\n\n\n"; tput sgr0
  exit 1
fi

if [ "$BOX" == "" ]; then
  tput setaf 1; printf "\n\nThe box name couldn't be parsed from the file name.\n\n\n"; tput sgr0
  exit 1
fi

if [ "$PROVIDER" == "" ]; then
  tput setaf 1; printf "\n\nThe provider couldn't be parsed from the file name.\n\n\n"; tput sgr0
  exit 1
fi

if [ "$VERSION" == "" ]; then
  tput setaf 1; printf "\n\nThe version couldn't be parsed from the file name.\n\n\n"; tput sgr0
  exit 1
fi

# Experimental retry function.
retry() {
  local count=1
  local result=0
  while [[ "${count}" -le 30 ]]; do
    [[ "${result}" -ne 0 ]] && {
      echo -e "\\n$(tput setaf 1)$FILENAME failed... retrying ${count} of 10.$(tput sgr0)\\n" >&2
    }
    "${@}" && { result=0 && break; } || result="${?}"
    count="$((count + 1))"

    # Increase the delay with each iteration.
    delay="$((delay + 20))"
    sleep $delay
  done

  [[ "${count}" -gt 3 ]] && {
    echo -e "\\n$(tput setaf 1)The command failed 10 times.$(tput sgr0)\\n" >&2
  }

  return "${result}"
}

(${CURL} \
  --tlsv1.2 \
  --silent \
  --retry 16 \
  --retry-delay 60 \
  --output /dev/null \
  --header "Content-Type: application/json" \
  --header "Authorization: Bearer $VAGRANT_CLOUD_TOKEN" \
  "https://app.vagrantup.com/api/v1/box/$ORG/$BOX/versions" \
  --data "
    {
      \"version\": {
        \"version\": \"$VERSION\",
        \"description\": \"A build environment for use in cross platform development.\"
      }
    }
  ") || (tput setaf 1; printf "Version creation failed. { $ORG $BOX $PROVIDER $VERSION }\n"; tput sgr0; exit)


(${CURL} \
  --silent \
  --retry 16 \
  --retry-delay 60 \
  --output /dev/null \
  --header "Authorization: Bearer $VAGRANT_CLOUD_TOKEN" \
  --request DELETE \
  https://app.vagrantup.com/api/v1/box/$ORG/$BOX/version/$VERSION/provider/${PROVIDER} )\
  || (tput setaf 1; printf "Unable to delete an existing version of the box. { $ORG $BOX $PROVIDER $VERSION }\n"; tput sgr0)

# Sleep to let the deletion propagate.
sleep 1

(${CURL} \
  --tlsv1.2 \
  --silent \
  --retry 16 \
  --retry-delay 60 \
  --output /dev/null \
  --header "Content-Type: application/json" \
  --header "Authorization: Bearer $VAGRANT_CLOUD_TOKEN" \
  https://app.vagrantup.com/api/v1/box/$ORG/$BOX/version/$VERSION/providers \
  --data "{ \"provider\": { \"name\": \"$PROVIDER\" } }" )\
  || (tput setaf 1; printf "Unable to delete an existing version of the box. { $ORG $BOX $PROVIDER $VERSION }\n"; tput sgr0; exit)

UPLOAD_PATH=`${CURL} \
  --tlsv1.2 \
  --silent \
  --header "Authorization: Bearer $VAGRANT_CLOUD_TOKEN" \
  https://app.vagrantup.com/api/v1/box/$ORG/$BOX/version/$VERSION/provider/$PROVIDER/upload | jq -r .upload_path`

if [ "$UPLOAD_PATH" == "" ] || [ "$UPLOAD_PATH" == "null" ]; then
  printf "\n\n$FILENAME failed to upload...\n\n"
  exit 1
fi

retry ${CURL} --tlsv1.2 \
  --silent  \
  --output "/dev/null" \
  --show-error \
  --request PUT \
  --max-time 7200 \
  --expect100-timeout 7200 \
  --header "Connection: keep-alive" \
  --write-out "FILE: $FILENAME\nCODE: %{http_code}\nIP: %{remote_ip}\nBYTES: %{size_upload}\nRATE: %{speed_upload}\nSETUP TIME: %{time_starttransfer}\nTOTAL TIME: %{time_total}\n\n" \
  --upload-file "$FILEPATH" "$UPLOAD_PATH"