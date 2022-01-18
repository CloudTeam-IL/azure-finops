## Deny certain tags policy
- This policy deny the desired tag's key.
- You have two parameters to input: one for the environment key. enter every option for this key you want to forbid
- Input example: ["env","envi","envir","enviro","environ","environm","environme","environmen","invironment","inviroment","enviroment"]
- The other is for all the other keys, enter every key you want to forbid.
- Input example: ["own","oner","app","aplication","costcenter","cost","ownercenter","finopsemail"]
- In addition, this policy deny all the environment tag's values except: production, dev,test,dr and qa 
