# delete-proton-prefix
A bash script to help you delete proton / steam prefixes

![image](https://github.com/user-attachments/assets/8cc718b2-f74f-4483-b660-28b07637c0bc)

## Note
Non-steam games in steam are currently not supported. Apparently some the data is located in $HOME/.steam/steam/userdata/*/config/shortcuts.vdf which is a binary file.
Pleaase submit a PR if you know how to fetch the name and appid for non-steam games properly.
I do not want to add too many dependencies to this, so try to keep it to bash, it's meant to be easy to use and small to install.
