This is the API

Policy functionality

1/ Policies are applied to groups and/or users
2/ Users are assigned some groups
3/ Users are defined by either hardcoded user definition OR Active Directory (in which case it will load the AD groups)
4/ Policies are files that look like AWS policies and are stored in the policies/ directory, in JSON format

Process to evaluate policy

1/ Load user
2/ Associate groups and policies
3/ Associate policies from groups (order).
(The groups are put into lowercase from AD, and spaces are converted to underscores)

At this point, the user has its policies in memory
Evaluate against the policies. Default is deny

Directories:
- etc/policies/
- etc/users/
- etc/groups.json

users format. someuser.json
```json
{
  "shadow": "pw in bcrypt format",
  "policies": [ "policy1", "policy2" ],
  "groups" : [ "group1", "group2" ]
}
```

groups.json
```json
{
  "somegroup":[ "policy1", "policy2" ],
  "someothergroup": [ "policy2" ] 
}
```

