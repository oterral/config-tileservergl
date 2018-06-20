#!/bin/bash
#
# A simple script that should be placed at the root of the git containing the configurations.
# The goal is to pull the configurations, and then copy them via scp where they truly belong.
# Since it might be in a public repository, users and adresses are to be put as parameters rather than hard coded.
set -e
set -u


GIT_PATH="."
DESTINATION_PATH=""
EFS_VOLUME=""
LOCAL_VOLUME=""
GROUP="mockup_geodata"
USER="mockup_geodata"



function usage {
  echo "Usage:"
  echo
  echo "-h --help"
  echo -e "--git \t The local git repository where your styles are stored. [default: .]"
  echo -e "--destination \t The path  where our configuration is supposed to end up inside the efs volume.[default:'']"
  echo -e "--efs \t the efs volume you wish to mount in read-write. [default: '']" 
  echo -e "--mnt \t the local repository used as a mount point for the efs. [default: '']"
  echo -e "example usage \t: updateStyle.sh --destination=\"temp\" --efs=\"[SERVER NAME]://dev/vectortiles\" --mnt=\
         \"/var/local/vectortiles\""
}

function cleanup {
  rm -rf "$OUTPUT_PATH"
  userdel "$USER"
  exit
}


if [ $# -gt 0 ]
  then
    while [ "${1:-}" != "" ]; do
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
            --destination)
                DESTINATION_PATH=${VALUE}
                ;;
            --efs)
                EFS_VOLUME=${VALUE}
                ;;
            --mnt)
                LOCAL_VOLUME=${VALUE}
                ;;
            *)
                echo "ERROR: unknown parameter \"${PARAM}\""
                usage
                exit 1
                ;;
        esac
        shift
  done
fi



trap cleanup SIGHUP SIGINT SIGTERM EXIT

#We pull the latest styles. Maybe it's not useful if it's in Jenkins and Jenkins take the latest config, but I'll leave it here for now.
git -C "$GIT_PATH" pull

groupadd "$GROUP" -g 2500
useradd -u 2500 -g 2500 "$USER"

let GIT_PATH_LENGTH=${#GIT_PATH}
#styles in correct files.
#  
# We look through each json file at the root of styles and extract the historic of their commits
# As well as the associated timestamps. We will then loop through those arrays (only arrays 
# allow to loop on two at the same times, thanks to identic indices) to create the necessary files

OUTPUT_PATH=$(sudo -u "$USER" mktemp -d)

#We make sure the efs is mounted or we mount it.
EFS_IS_MOUNTED_TO_LOCAL_VOLUME=$(grep "$EFS_VOLUME $LOCAL_VOLUME nfs4 rw" /proc/mounts || echo "")

EFS_IS_MOUNTED=$(grep "$EFS_VOLUME" /proc/mounts | grep nfs4 | grep rw || echo "")

if [ ${#EFS_IS_MOUNTED} -eq 0 ]
  then
    echo "mounting efs..."
    sudo -u "$USER" mkdir -p "$LOCAL_VOLUME"
    mount.nfs4 "$EFS_VOLUME" "$LOCAL_VOLUME" -w
    echo "efs mounted"
elif [ ${#EFS_IS_MOUNTED_TO_LOCAL_VOLUME} -eq 0 ]
  then
    echo "error: efs is already mounted somewhere else. The local volume directive must be the mounting point of the efs or the efs should not be mounted on this device."
    exit 2
fi

sudo -u "$USER" mkdir -p "$LOCAL_VOLUME/$DESTINATION_PATH"

echo
echo "Starting to process styles"

for directory in "$GIT_PATH"/styles/*
do
#we take the commits hash and timestamps and put them into two arrays 
  IFS='  
' read -r -a COMMIT <<< $(git -C "$GIT_PATH" log --pretty=format:%H -- "$directory")
  read -r -a TIME <<< $(git -C "$GIT_PATH" log --pretty=format:%at -- "$directory")
  let DIR_NAME_LENGTH=${#directory}
  let DIR_NAME_LENGTH-=8
  let DIR_NAME_LENGTH-=$GIT_PATH_LENGTH

# Bash magic : we take the output path, add a "styles" directory and we take only the name of the file
# without the extension. It will become the base directory that hosts all versions.
#I call it magic because it's not that readable

  BASE_PATH="$OUTPUT_PATH/${directory:$GIT_PATH_LENGTH+1}"
  for index in "${!COMMIT[@]}"
    do
#The path to the specific version of the style is created. the UNIX timestamp is first
#to allow ordering if needed. If there is already a directory created, we don't 
#operate on this version and shifts to the next : the file already exists and 
#doesn't need to be written over.
      PATH_TO_VERSION="$BASE_PATH/${TIME[index]}_${COMMIT[index]}"
      if [ ! -d "$PATH_TO_VERSION" ]
        then
          sudo -u "$USER" mkdir -p "$PATH_TO_VERSION"
          IFS=' '
# The git show COMMIT:FILE  command returns the content of the file as it was 
#during the specified commit. We store that in a json. 
          FILES_IN_VERSION=$(git -C "$GIT_PATH" show "${COMMIT[index]}":"${directory:$GIT_PATH_LENGTH+1}" | grep '.png\|.json' || echo "")
          while read -r line
            do
              git -C "$GIT_PATH" show "${COMMIT[index]}:$directory/$line"> "$PATH_TO_VERSION/$line" || echo  ""
            done <<< $FILES_IN_VERSION
      fi 
    done
  
done

#we copy the fonts and sprites from the repository, if they need to be updated / are more recent / do not exist

 
sudo -u "$USER" cp -r -u "$GIT_PATH/fonts" "$OUTPUT_PATH/fonts"
#rsync between the destination folder in the EFS and the local styles, font and sprites directory
echo "Starting to rsync"
sudo -u "$USER" rsync -avzh "$OUTPUT_PATH/" "$LOCAL_VOLUME/$DESTINATION_PATH"

echo "Creating symlinks to current"

#for each style directory
#apparently, loops over find are 'weak'. I'll use something better when I have time to do so
IFS=$'\n'
for directory in $(find "$LOCAL_VOLUME/$DESTINATION_PATH/styles" -maxdepth 1 -mindepth 1 -type d -printf '%f\n')
  do
    #we find the directory with the highest timestamp inside this one
    CURRENT_VERSION=$(find "$LOCAL_VOLUME/$DESTINATION_PATH/styles/$directory" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' | sort -r | sed -n 1p)
   
    sudo -u "$USER" ln -sf "$LOCAL_VOLUME/$DESTINATION_PATH/styles/$directory/$CURRENT_VERSION" "$LOCAL_VOLUME/$DESTINATION_PATH/styles/$directory/current"
#TODO : ln -sfn won't create the link if it doesn't exist, but -sf won't update it. I'll have to look into that
  done
