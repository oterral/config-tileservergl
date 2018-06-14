#!/bin/bash
#
# A simple script that should be placed at the root of the git containing the configurations.
# The goal is to pull the configurations, and then copy them via scp where they truly belong.
# Since it might be in a public repository, users and adresses are to be put as parameters rather than hard coded.
set -e



GIT_PATH="."
OUTPUT_PATH="/temp/styling"
REMOTE_USER=""
REMOTE_SERVER=""
DESTINATION_PATH=""
SSH_FLAG="false"
function usage {
  echo "Usage:"
  echo
  echo "-h --help"
  echo -e "--output \t The local path  where we should store our styles. default is /var/styling"
  echo -e "--git \t The local git repository where your styles are stored"
  echo -e "--rmu \t The Remote user to connect to the remote server destined to host the configuration"
  echo -e "--rms \t The address (ip or dns) of the remote server."
  echo -e "--dp \t The path inside where our configuration is supposed to end up."
  echo -e "--ssh \t (No value) : put this option if your destination is on a remote server and you need ssh."  
  echo -e "example usage \t : updateStyle --output=\"/var/styling\" \
--git=\"./\" --rmu=\"definitivelyNotRoot\" \
--rms=\"ourFantasticBackend.ch\" --dp=\"/Store/Styling/Here/Please\" --ssh"
}

while [ "${1}" != "" ]; do
    PARAM=$(echo "${1}" | awk -F= '{print $1}')
    VALUE=$(echo "${1}" | awk -F= '{print $2}')
    case ${PARAM} in
        --help)
            usage
            exit
            ;;
        --git)
            GIT_PATH=${VALUE}
            ;;
        --output)
            OUTPUT_PATH=${VALUE}
            ;;
        --rmu)
            REMOTE_USER=${VALUE}
            ;;
        --rms)
            REMOTE_SERVER=${VALUE}
            ;;
        --dp)
            DESTINATION_PATH=${VALUE}
            ;;
        --ssh)
            SSH_FLAG="true"
            ;;
        *)
            echo "ERROR: unknown parameter \"${PARAM}\""
            usage
            exit 1
            ;;
    esac
    shift
done

#Here, we will verify if GIT_PATH is a git repository.
#There is no directory : git clone at the parent
#there is a non git directory : we destroy and we clone at parent
#there is a git repo : we pull

#first case : no directory

git -C "$GIT_PATH" pull

let LENPTG=${#GIT_PATH}

#styles in correct files.
#  
# We look through each json file at the root of styles and extract the historic of their commits
# As well as the associated timestamps. We will then loop through those arrays (only arrays 
# allow to loop on two at the same times, thanks to identic indices) to create the necessary files

mkdir -p "$OUTPUT_PATH"
for style in "$GIT_PATH"/styles/*.json
do

#we take the commits hash and timestamps and put them into two arrays 

  IFS='  
' read -r -a COMMIT <<< $(git -C "$GIT_PATH" log --pretty=format:%H -- "$style")
  IFS='
' read -r -a TIME <<< $(git -C "$GIT_PATH" log --pretty=format:%at -- "$style")
  let LOTP=${#style}

# Bash magic : we take the output path, add a "styles" directory and we take only the name of the file
# without the extension. It will become the base directory that hosts all versions.
#I call it magic because it's not that readable

  BASEPATH="$OUTPUT_PATH/styles/${style:$LENPTG+8:$LTOP+-5}"
  for index in "${!COMMIT[@]}"
    do

#The path to the specific version of the style is created. the UNIX timestamp is first
#to allow ordering if needed. If there is already a directory created, we don't 
#operate on this version and shifts to the next : the file already exists and 
#doesn't need to be written over.

      PATHTOVERSION="$BASEPATH/${TIME[index]}_${COMMIT[index]}"
      if [ ! -d "$PATHTOVERSION" ]
        then
        mkdir -p "$PATHTOVERSION"

#Since the most recent commit will be called first, at index 0 we have the most recent commit.
#We assume that the most recent commit to a style should be the "current" version for that style
        
        if [ "$index" = "0" ]
          then
          ln -sf "$PATHTOVERSION" "$BASEPATH/current"

# The git show COMMIT:FILE  command returns the content of the file as it was 
#during the specified commit. We store that in a json. 
          
          git -C "$GIT_PATH" show "${COMMIT[INDEX]}":"${style:$LENPTG+1}" > "$PATHTOVERSION/style.json"

        fi 
      fi
    done
  
done

#we copy the fonts and sprites from the repository, if they need to be updated / are more recent / do not exist

cp -r -u "$GIT_PATH/fonts" "$OUTPUT_PATH/fonts"
cp -r -u "$GIT_PATH/sprites" "$OUTPUT_PATH/sprites"

#rsync between the destination folder in the EFS and the local styles, font and sprites directory
if [ $SSH_FLAG = "true" ]
  then
    rsync -avzhe ssh "$OUTPUT_PATH" "$REMOTE_USER"@"$REMOTE_SERVER":"$DESTINATION_PATH"
else
    rsync -avzhe "$OUTPUT_PATH" "$DESTINATION_PATH"
fi

