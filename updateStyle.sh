#!/bin/bash
#
# A simple script that should be placed at the root of the git containing the configurations.
# The goal is to pull the configurations, and then copy them via scp where they truly belong.
# Since it might be in a public repository, users and adresses are to be put as parameters rather than hard coded.
set -e
set -u


git_path="."
destination_path=""
efs_volume=""
local_volume=""
fonts_update=0
GROUP="mockup_geodata"
user="mockup_geodata"



function usage {
  echo "Usage:"
  echo
  echo "-h --help"
  echo -e "--git \t The local git repository where your styles are stored. [default: .]"
  echo -e "--destination \t The path  where our configuration is supposed to end up inside the efs volume.[default:'']"
  echo -e "--efs \t the efs volume you wish to mount in read-write. [default: '']" 
  echo -e "--mnt \t the local repository used as a mount point for the efs. [default: '']"
  echo -e "--fonts \t as the fonts syncing is a time consuming operation, it is \
disabled by default. the --fonts flag will tell the script upload the fonts, which \
will make the script run for a much longer time and you will cry when it happens. \
To be called when new fonts are pushed, or when you push the content to a whole new directory"
  echo -e "example usage \t: updateStyle.sh --destination=\"temp\" --efs=\"[SERVER NAME]://dev/vectortiles\" --mnt=\
         \"/var/local/vectortiles\""
}

function cleanup {
  rm -rf "$output_path"
  userdel "$user"
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
                git_path=${VALUE}
                ;;
            --destination)
                destination_path=${VALUE}
                ;;
            --efs)
                efs_volume=${VALUE}
                ;;
            --mnt)
                local_volume=${VALUE}
                ;;
            --fonts)
                fonts_update=1
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

SECONDS=0

trap cleanup SIGHUP SIGINT SIGTERM EXIT

#We pull the latest styles. Maybe it's not useful if it's in Jenkins and Jenkins take the latest config, but I'll leave it here for now.
git -C "$git_path" pull

groupadd "$GROUP" -g 2500
useradd -u 2500 -g 2500 "$user"

let git_path_length=${#git_path}
#styles in correct files.
#  
# We look through each json file at the root of styles and extract the historic of their commits
# As well as the associated timestamps. We will then loop through those arrays (only arrays 
# allow to loop on two at the same times, thanks to identic indices) to create the necessary files

output_path=$(sudo -u "$user" mktemp -d)

#We make sure the efs is mounted or we mount it.
efs_is_mounted_to_local_volume=$(grep "$efs_volume $local_volume nfs4 rw" /proc/mounts || echo "")

efs_is_mounted=$(grep "$efs_volume" /proc/mounts | grep nfs4 | grep rw || echo "")

if [ ${#efs_is_mounted} -eq 0 ]
  then
    echo "mounting efs..."
    sudo -u "$user" mkdir -p "$local_volume"
    mount.nfs4 "$efs_volume" "$local_volume" -w
    echo "efs mounted"
elif [ ${#efs_is_mounted_to_local_volume} -eq 0 ]
  then
    echo "error: efs is already mounted somewhere else. The local volume directive must be the mounting point of the efs or the efs should not be mounted on this device."
    exit 2
fi

sudo -u "$user" mkdir -p "$local_volume/$destination_path"

echo
echo "Starting to process styles"

for directory in "$git_path"/styles/*
do
#we take the commits hash and timestamps and put them into two arrays 
  IFS='  
' read -r -a commit <<< $(git -C "$git_path" log --pretty=format:%H -- "$directory")
  read -r -a time <<< $(git -C "$git_path" log --pretty=format:%at -- "$directory")
  let dir_name_length=${#directory}
  let dir_name_length-=8
  let dir_name_length-=$git_path_length

# Bash magic : we take the output path, add a "styles" directory and we take only the name of the file
# without the extension. It will become the base directory that hosts all versions.
#I call it magic because it's not that readable

  base_path="$output_path/${directory:$git_path_length+1}"
  for index in "${!commit[@]}"
    do
#The path to the specific version of the style is created. the UNIX timestamp is first
#to allow ordering if needed. If there is already a directory created, we don't 
#operate on this version and shifts to the next : the file already exists and 
#doesn't need to be written over.
      version_path="$base_path/${time[index]}_${commit[index]}"
      if [ ! -d "$version_path" ]
        then
          sudo -u "$user" mkdir -p "$version_path"
          IFS=' '
# The git show commit:FILE  command returns the content of the file as it was 
#during the specified commit. We store that in a json. 
          versionned_files=$(git -C "$git_path" show "${commit[index]}":"${directory:$git_path_length+1}" | grep '.png\|.json' || echo "")
          while read -r line
            do
              git -C "$git_path" show "${commit[index]}:$directory/$line"> "$version_path/$line" || echo  ""
            done <<< $versionned_files
      fi 
    done
  
done

 #for fonts, we are going for a recursive update copy. It will be faster than a copy and only overwrites more recent files rather than copying everything.
if [[ $fonts_update = 1 ]]
  then
   echo "fonts update required. Copying fonts to temporary folder"
   sudo -u "$user" cp -r -u "$git_path/fonts" "$output_path/fonts"
fi
#rsync between the destination folder in the EFS and the local styles, font and sprites directory
echo "Starting to rsync"

sudo -u "$user" rsync -avzh "$output_path/" "$local_volume/$destination_path"

echo "Creating symlinks"
#for each style directory
#apparently, loops over find are 'weak'. I'll use something better when I have time to do so


IFS=$'\n'
for directory in "$local_volume/$destination_path"/styles/*/
  do
    #we find the directory with the highest timestamp inside this one
    current_version=$(find "$directory" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' | sort -r | sed -n 1p)
    if [ -L "$directory"current ]
      then
        
        sudo -u "$user" ln -sfn "$directory""$current_version" "$directory"current
    else   
        sudo -u "$user" ln -sf "$directory""$current_version" "$directory"current
    fi
  done

duration=$SECONDS
echo "Elapsed time: $((duration / 60)) minutes and $((duration % 60)) seconds."

