fd target -I --type f --strip-cwd-prefix -x sha1sum {} | awk '{ print $2 ":" $1 }' | sort
