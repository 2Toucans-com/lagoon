#!/bin/bash

set -eo pipefail

# 1. The first part of this entrypoint script deals with adding realms and users. Code is a modified version of this entrypoint script:
# https://github.com/stefanjacobs/keycloak_min/blob/f26927426e60c1ec29fc0c0980e5a694a45dcc05/run.sh

function is_keycloak_running {
    local http_code=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/auth/admin/realms)
    if [[ $http_code -eq 401 ]]; then
        return 0
    else
        return 1
    fi
}

function configure_lagoon_realm {
    if /opt/jboss/keycloak/bin/kcadm.sh get realms/$KEYCLOAK_REALM --config $CONFIG_PATH > /dev/null; then
        echo "Realm $KEYCLOAK_REALM is already created, skipping initial setup"
        return 0
    fi

    if [ $KEYCLOAK_REALM ]; then
        echo Creating realm $KEYCLOAK_REALM
        /opt/jboss/keycloak/bin/kcadm.sh create realms --config $CONFIG_PATH -s realm=$KEYCLOAK_REALM -s enabled=true
    fi

    if [ "$KEYCLOAK_REALM_ROLES" ]; then
        for role in ${KEYCLOAK_REALM_ROLES//,/ }; do
            echo Creating role $role
            /opt/jboss/keycloak/bin/kcadm.sh create roles --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -s name=${role}
        done
    fi

    # Configure keycloak for searchguard
    echo Creating client searchguard
    echo '{"clientId": "searchguard", "webOrigins": ["*"], "redirectUris": ["*"]}' | /opt/jboss/keycloak/bin/kcadm.sh create clients --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -f -
    echo Creating mapper for searchguard "groups"
    CLIENT_ID=$(/opt/jboss/keycloak/bin/kcadm.sh get  -r lagoon clients?clientId=searchguard --config $CONFIG_PATH | python -c 'import sys, json; print json.load(sys.stdin)[0]["id"]')
    echo '{"protocol":"openid-connect","config":{"full.path":"false","id.token.claim":"true","access.token.claim":"true","userinfo.token.claim":"true","claim.name":"groups"},"name":"groups","protocolMapper":"oidc-group-membership-mapper"}' | /opt/jboss/keycloak/bin/kcadm.sh create -r ${KEYCLOAK_REALM:-master} clients/$CLIENT_ID/protocol-mappers/models --config $CONFIG_PATH -f -

    # Configure keycloak for ui
    echo Creating client lagoon-ui
    echo '{"clientId": "lagoon-ui", "publicClient": true, "webOrigins": ["*"], "redirectUris": ["*"]}' | /opt/jboss/keycloak/bin/kcadm.sh create clients --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -f -
    echo Creating mapper for lagoon-ui "lagoon-uid"
    CLIENT_ID=$(/opt/jboss/keycloak/bin/kcadm.sh get  -r lagoon clients?clientId=lagoon-ui --config $CONFIG_PATH | python -c 'import sys, json; print json.load(sys.stdin)[0]["id"]')
    echo '{"protocol":"openid-connect","config":{"id.token.claim":"true","access.token.claim":"true","userinfo.token.claim":"true","user.attribute":"lagoon-uid","claim.name":"lagoon.user_id","jsonType.label":"int","multivalued":""},"name":"Lagoon User ID","protocolMapper":"oidc-usermodel-attribute-mapper"}' | /opt/jboss/keycloak/bin/kcadm.sh create -r ${KEYCLOAK_REALM:-master} clients/$CLIENT_ID/protocol-mappers/models --config $CONFIG_PATH -f -

    if [ "$KEYCLOAK_REALM_SETTINGS" ]; then
        echo Applying extra Realm settings
        echo $KEYCLOAK_REALM_SETTINGS | /opt/jboss/keycloak/bin/kcadm.sh update realms/${KEYCLOAK_REALM:-master} --config $CONFIG_PATH -f -
    fi

    if [ $KEYCLOAK_LAGOON_ADMIN_USERNAME ]; then
        echo Creating user $KEYCLOAK_LAGOON_ADMIN_USERNAME
        # grep would have been nice instead of the double sed, but we don't have gnu grep available, only the busybox grep which is very limited
        local user_id=$(echo '{"username": "'$KEYCLOAK_LAGOON_ADMIN_USERNAME'", "enabled": true}' \
        | /opt/jboss/keycloak/bin/kcadm.sh create users --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -f - 2>&1  | sed -e 's/Created new user with id //g' -e "s/'//g")
        echo "Created user with id ${user_id}"
        /opt/jboss/keycloak/bin/kcadm.sh update users/${user_id}/reset-password --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -s type=password -s value=${KEYCLOAK_LAGOON_ADMIN_PASSWORD} -s temporary=false -n
        echo "Set password for user ${user_id}"

        /opt/jboss/keycloak/bin/kcadm.sh add-roles --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} --uid ${user_id} --rolename admin
        echo "Gave user '$KEYCLOAK_LAGOON_ADMIN_USERNAME' the role 'admin'"

        local group_name="lagoonadmin"
        local group_id=$(/opt/jboss/keycloak/bin/kcadm.sh create groups --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -s name=${group_name} 2>&1 | sed -e 's/Created new group with id //g' -e "s/'//g")
        /opt/jboss/keycloak/bin/kcadm.sh update users/${user_id}/groups/${group_id} --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master}
        echo "Created group '$group_name' and made user '$KEYCLOAK_LAGOON_ADMIN_USERNAME' member of it"
    fi
}

function configure_api_client {
    api_client_id=$(/opt/jboss/keycloak/bin/kcadm.sh get -r lagoon clients?clientId=api --config $CONFIG_PATH)
    if [ "$api_client_id" != "[ ]" ]; then
        echo "Client api is already created, skipping basic setup"
        return 0
    fi

    # Enable username edit
    /opt/jboss/keycloak/bin/kcadm.sh update realms/${KEYCLOAK_REALM:-master} --config $CONFIG_PATH -s editUsernameAllowed=true

    echo Creating client auth-server
    echo '{"clientId": "auth-server", "publicClient": false, "standardFlowEnabled": false, "serviceAccountsEnabled": true, "secret": "'$KEYCLOAK_AUTH_SERVER_CLIENT_SECRET'"}' | /opt/jboss/keycloak/bin/kcadm.sh create clients --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -f -
    AUTH_SERVER_CLIENT_ID=$(/opt/jboss/keycloak/bin/kcadm.sh get  -r lagoon clients?clientId=auth-server --config $CONFIG_PATH | python -c 'import sys, json; print json.load(sys.stdin)[0]["id"]')
    REALM_MANAGEMENT_CLIENT_ID=$(/opt/jboss/keycloak/bin/kcadm.sh get  -r lagoon clients?clientId=realm-management --config $CONFIG_PATH | python -c 'import sys, json; print json.load(sys.stdin)[0]["id"]')
    echo Enable auth-server token exchange
    # 1 Enable fine grained admin permissions for users
    /opt/jboss/keycloak/bin/kcadm.sh update users-management-permissions --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -s enabled=true
    # 2 Enable fine grained admin perions for client
    /opt/jboss/keycloak/bin/kcadm.sh update clients/$AUTH_SERVER_CLIENT_ID/management/permissions --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -s enabled=true
    # 3 Create policy for auth-server client
    echo '{"type":"client","logic":"POSITIVE","decisionStrategy":"UNANIMOUS","name":"Client auth-server Policy","clients":["'$AUTH_SERVER_CLIENT_ID'"]}' | /opt/jboss/keycloak/bin/kcadm.sh create clients/$REALM_MANAGEMENT_CLIENT_ID/authz/resource-server/policy/client --config $CONFIG_PATH -r lagoon -f -
    AUTH_SERVER_CLIENT_POLICY_ID=$(/opt/jboss/keycloak/bin/kcadm.sh get -r lagoon clients/$REALM_MANAGEMENT_CLIENT_ID/authz/resource-server/policy?name=Client+auth-server+Policy --config $CONFIG_PATH | python -c 'import sys, json; print json.load(sys.stdin)[0]["id"]')
    # 4 Update user impersonate permission to add client policy (PUT)
    IMPERSONATE_PERMISSION_ID=$(/opt/jboss/keycloak/bin/kcadm.sh get -r lagoon clients/$REALM_MANAGEMENT_CLIENT_ID/authz/resource-server/permission?name=admin-impersonating.permission.users --config $CONFIG_PATH | python -c 'import sys, json; print json.load(sys.stdin)[0]["id"]')
    /opt/jboss/keycloak/bin/kcadm.sh update clients/$REALM_MANAGEMENT_CLIENT_ID/authz/resource-server/permission/scope/$IMPERSONATE_PERMISSION_ID --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -s 'policies=["'$AUTH_SERVER_CLIENT_POLICY_ID'"]'



    # Setup composite roles. Each role will include the roles to the left of it
    composite_role_names=(guest reporter developer maintainer owner)
    composites_add=()
    for crn_key in ${!composite_role_names[@]}; do
        echo Creating role ${composite_role_names[$crn_key]}
        /opt/jboss/keycloak/bin/kcadm.sh create roles --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -s composite=true -s name=${composite_role_names[$crn_key]}

        for ca_key in ${!composites_add[@]}; do
            /opt/jboss/keycloak/bin/kcadm.sh add-roles --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} --rname ${composite_role_names[$crn_key]} --rolename ${composites_add[$ca_key]}
        done

        composites_add+=(${composite_role_names[$crn_key]})
    done

    # Configure keycloak for api
    echo Creating client api
    echo '{"clientId": "api", "publicClient": false, "standardFlowEnabled": false, "serviceAccountsEnabled": true, "authorizationServicesEnabled": true, "secret": "'$KEYCLOAK_API_CLIENT_SECRET'"}' | /opt/jboss/keycloak/bin/kcadm.sh create clients --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -f -
    CLIENT_ID=$(/opt/jboss/keycloak/bin/kcadm.sh get  -r lagoon clients?clientId=api --config $CONFIG_PATH | python -c 'import sys, json; print json.load(sys.stdin)[0]["id"]')
    ADMIN_ROLE_ID=$(/opt/jboss/keycloak/bin/kcadm.sh get  -r lagoon roles/admin --config $CONFIG_PATH | python -c 'import sys, json; print json.load(sys.stdin)["id"]')
    GUEST_ROLE_ID=$(/opt/jboss/keycloak/bin/kcadm.sh get  -r lagoon roles/guest --config $CONFIG_PATH | python -c 'import sys, json; print json.load(sys.stdin)["id"]')
    REPORTER_ROLE_ID=$(/opt/jboss/keycloak/bin/kcadm.sh get  -r lagoon roles/reporter --config $CONFIG_PATH | python -c 'import sys, json; print json.load(sys.stdin)["id"]')
    DEVELOPER_ROLE_ID=$(/opt/jboss/keycloak/bin/kcadm.sh get  -r lagoon roles/developer --config $CONFIG_PATH | python -c 'import sys, json; print json.load(sys.stdin)["id"]')
    MAINTAINER_ROLE_ID=$(/opt/jboss/keycloak/bin/kcadm.sh get  -r lagoon roles/maintainer --config $CONFIG_PATH | python -c 'import sys, json; print json.load(sys.stdin)["id"]')
    OWNER_ROLE_ID=$(/opt/jboss/keycloak/bin/kcadm.sh get  -r lagoon roles/owner --config $CONFIG_PATH | python -c 'import sys, json; print json.load(sys.stdin)["id"]')

    # Resource Scopes
    resource_scope_names=(add addGroup addNoExec addNotification addOrUpdate addUser delete deleteAll deleteNoExec deploy drushArchiveDump drushCacheClear drushRsync drushSqlDump drushSqlSync environment:add environment:view getBySshKey project:add project:view removeAll removeGroup removeNotification removeUser ssh storage task:destination task:source token type:development type:production udpate view view:user viewAll viewPrivateKey)
    for rsn_key in ${!resource_scope_names[@]}; do
        echo Creating resource scope ${resource_scope_names[$rsn_key]}
        /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/scope --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -s name=${resource_scope_names[$rsn_key]}
    done

    # Resources with scopes
    echo Creating resource backup
    echo '{"name":"backup","displayName":"backup","scopes":[{"name":"view"},{"name":"add"},{"name":"delete"},{"name":"deleteAll"}],"attributes":{},"uris":[],"ownerManagedAccess":""}' | /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/resource --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -f -
    echo Creating resource restore
    echo '{"name":"restore","displayName":"restore","scopes":[{"name":"add"},{"name":"addNoExec"},{"name":"update"}],"attributes":{},"uris":[],"ownerManagedAccess":""}' | /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/resource --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -f -
    echo Creating resource deployment
    echo '{"name":"deployment","displayName":"deployment","scopes":[{"name":"view"},{"name":"update"},{"name":"delete"}],"attributes":{},"uris":[],"ownerManagedAccess":""}' | /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/resource --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -f -
    echo Creating resource env_var
    echo '{"name":"env_var","displayName":"env_var","scopes":[{"name":"project:view"},{"name":"project:add"},{"name":"environment:view"},{"name":"environment:add"},{"name":"type:production"},{"name":"type:development"},{"name":"delete"}],"attributes":{},"uris":[],"ownerManagedAccess":""}' | /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/resource --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -f -
    echo Creating resource task
    echo '{"name":"task","displayName":"task","scopes":[{"name":"view"},{"name":"update"},{"name":"delete"},{"name":"add"},{"name":"addNoExec"},{"name":"drushArchiveDump"},{"name":"drushSqlDump"},{"name":"drushCacheClear"},{"name":"drushSqlSync"},{"name":"drushRsync"},{"name":"type:production"},{"name":"type:development"},{"name":"task:source"},{"name":"task:destination"}],"attributes":{},"uris":[],"ownerManagedAccess":""}' | /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/resource --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -f -
    echo Creating resource openshift
    echo '{"name":"openshift","displayName":"openshift","scopes":[{"name":"add"},{"name":"delete"},{"name":"update"},{"name":"deleteAll"},{"name":"view"},{"name":"viewAll"},{"name":"token"}],"attributes":{},"uris":[],"ownerManagedAccess":""}' | /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/resource --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -f -
    echo Creating resource user
    echo '{"name":"user","displayName":"user","scopes":[{"name":"add"},{"name":"getBySshKey"},{"name":"update"},{"name":"delete"},{"name":"deleteAll"}],"attributes":{},"uris":[],"ownerManagedAccess":""}' | /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/resource --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -f -
    echo Creating resource environment
    echo '{"name":"environment","displayName":"environment","scopes":[{"name":"ssh"},{"name":"view"},{"name":"deploy"},{"name":"type:production"},{"name":"type:development"},{"name":"addOrUpdate"},{"name":"storage"},{"name":"delete"},{"name":"deleteNoExec"},{"name":"update"},{"name":"viewAll"},{"name":"deleteAll"}],"attributes":{},"uris":[],"ownerManagedAccess":""}' | /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/resource --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -f -
    echo Creating resource project
    echo '{"name":"project","displayName":"project","scopes":[{"name":"update"},{"name":"add"},{"name":"deploy"},{"name":"addGroup"},{"name":"removeGroup"},{"name":"addNotification"},{"name":"removeNotification"},{"name":"view"},{"name":"delete"},{"name":"deleteAll"},{"name":"viewAll"},{"name":"viewPrivateKey"}],"attributes":{},"uris":[],"ownerManagedAccess":""}' | /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/resource --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -f -
    echo Creating resource group
    echo '{"name":"group","displayName":"group","scopes":[{"name":"add"},{"name":"update"},{"name":"delete"},{"name":"deleteAll"},{"name":"addUser"},{"name":"removeUser"}],"attributes":{},"uris":[],"ownerManagedAccess":""}' | /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/resource --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -f -
    echo Creating resource notification
    echo '{"name":"notification","displayName":"notification","scopes":[{"name":"add"},{"name":"delete"},{"name":"view"},{"name":"deleteAll"},{"name":"removeAll"},{"name":"update"}],"attributes":{},"uris":[],"ownerManagedAccess":""}' | /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/resource --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -f -
    echo Creating resource ssh_key
    echo '{"name":"ssh_key","displayName":"ssh_key","scopes":[{"name":"view:user"},{"name":"view:project"},{"name":"add"},{"name":"deleteAll"},{"name":"removeAll"},{"name":"update"},{"name":"delete"}],"attributes":{},"uris":[],"ownerManagedAccess":""}' | /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/resource --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -f -

    # Authorization policies
    echo Creating api authz role policies
    echo '{"type":"role","logic":"POSITIVE","decisionStrategy":"UNANIMOUS","name":"Admin Role Policy","description":"User has admin role","roles":[{"id":"'$ADMIN_ROLE_ID'","required":true}]}' | /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/policy/role --config $CONFIG_PATH -r lagoon -f -
    echo '{"type":"role","logic":"POSITIVE","decisionStrategy":"UNANIMOUS","name":"Guest Role Policy","description":"User has guest role","roles":[{"id":"'$GUEST_ROLE_ID'","required":true}]}' | /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/policy/role --config $CONFIG_PATH -r lagoon -f -
    echo '{"type":"role","logic":"POSITIVE","decisionStrategy":"UNANIMOUS","name":"Reporter Role Policy","description":"User has reporter role","roles":[{"id":"'$REPORTER_ROLE_ID'","required":true}]}' | /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/policy/role --config $CONFIG_PATH -r lagoon -f -
    echo '{"type":"role","logic":"POSITIVE","decisionStrategy":"UNANIMOUS","name":"Developer Role Policy","description":"User has developer role","roles":[{"id":"'$DEVELOPER_ROLE_ID'","required":true}]}' | /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/policy/role --config $CONFIG_PATH -r lagoon -f -
    echo '{"type":"role","logic":"POSITIVE","decisionStrategy":"UNANIMOUS","name":"Maintainer Role Policy","description":"User has maintainer role","roles":[{"id":"'$MAINTAINER_ROLE_ID'","required":true}]}' | /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/policy/role --config $CONFIG_PATH -r lagoon -f -
    echo '{"type":"role","logic":"POSITIVE","decisionStrategy":"UNANIMOUS","name":"Owner Role Policy","description":"User has owner role","roles":[{"id":"'$OWNER_ROLE_ID'","required":true}]}' | /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/policy/role --config $CONFIG_PATH -r lagoon -f -

    echo Creating api authz js policies
    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/policy/js --config $CONFIG_PATH -r lagoon -f - <<'EOF'
{
  "name": "Users role for group is Developer",
  "description": "Checks the users role for a group is Developer or higher",
  "type": "js",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "code": "var ctx = $evaluation.getContext();\nvar ctxAttr = ctx.getAttributes();\nvar validRoles = {\n    owner: 1,\n    maintainer: 1,\n    developer: 1,\n    reporter: 0,\n    guest: 0,\n};\n\nif (!ctxAttr.exists('userGroupRole')) {\n    $evaluation.deny();\n} else {\n    var groupRole = ctxAttr.getValue('userGroupRole').asString(0);\n\n    if (validRoles[groupRole.toLowerCase()]) {\n        $evaluation.grant();\n    } else {\n        $evaluation.deny();\n    }\n}"
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/policy/js --config $CONFIG_PATH -r lagoon -f - <<'EOF'
{
  "name": "Users role for project is Developer",
  "description": "Checks the users role for a project is Developer or higher",
  "type": "js",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "code": "var ctx = $evaluation.getContext();\nvar ctxAttr = ctx.getAttributes();\nvar validRoles = {\n    owner: 1,\n    maintainer: 1,\n    developer: 1,\n    reporter: 0,\n    guest: 0,\n};\n\nif (!ctxAttr.exists('userProjectRole')) {\n    $evaluation.deny();\n} else {\n    var groupRole = ctxAttr.getValue('userProjectRole').asString(0);\n\n    if (validRoles[groupRole.toLowerCase()]) {\n        $evaluation.grant();\n    } else {\n        $evaluation.deny();\n    }\n}"
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/policy/js --config $CONFIG_PATH -r lagoon -f - <<'EOF'
{
  "name": "User has access to project",
  "description": "Checks that the user has access to a project via groups",
  "type": "js",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "code": "var ctx = $evaluation.getContext();\nvar ctxAttr = ctx.getAttributes();\n\nif (!ctxAttr.exists('projectQuery') || !ctxAttr.exists('userProjects')) {\n    $evaluation.deny();\n} else {\n    var project = ctxAttr.getValue('projectQuery').asString(0);\n    var projects = ctxAttr.getValue('userProjects').asString(0);\n    var projectsArr = projects.split('-');\n    var grant = false;\n\n    for (var i=0; i<projectsArr.length; i++) {\n        if (project == projectsArr[i]) {\n            grant = true;\n            break;\n        }\n    }\n\n    if (grant) {\n        $evaluation.grant();\n    } else {\n        $evaluation.deny();\n    }\n}\n\n"
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/policy/js --config $CONFIG_PATH -r lagoon -f - <<'EOF'
{
  "name": "Users role for project is Reporter",
  "description": "Checks the users role for a project is Reporter or higher",
  "type": "js",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "code": "var ctx = $evaluation.getContext();\nvar ctxAttr = ctx.getAttributes();\nvar validRoles = {\n    owner: 1,\n    maintainer: 1,\n    developer: 1,\n    reporter: 1,\n    guest: 0,\n};\n\nif (!ctxAttr.exists('userProjectRole')) {\n    $evaluation.deny();\n} else {\n    var groupRole = ctxAttr.getValue('userProjectRole').asString(0);\n\n    if (validRoles[groupRole.toLowerCase()]) {\n        $evaluation.grant();\n    } else {\n        $evaluation.deny();\n    }\n}"
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/policy/js --config $CONFIG_PATH -r lagoon -f - <<'EOF'
{
  "name": "User has access to own data",
  "description": "Checks that the current user is same as queried",
  "type": "js",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "code": "var ctx = $evaluation.getContext();\nvar ctxAttr = ctx.getAttributes();\n\nif (!ctxAttr.exists('usersQuery') || !ctxAttr.exists('currentUser')) {\n    $evaluation.deny();\n} else {\n    var currentUser = ctxAttr.getValue('currentUser').asString(0);\n    var users = ctxAttr.getValue('usersQuery').asString(0);\n    var usersArr = users.split('|');\n    var grant = false;\n    \n    for (var i=0; i<usersArr.length; i++) {\n        if (currentUser == usersArr[i]) {\n            grant = true;\n            break;\n        }\n    }\n\n    if (grant) {\n        $evaluation.grant();\n    } else {\n        $evaluation.deny();\n    }\n}"
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/policy/js --config $CONFIG_PATH -r lagoon -f - <<'EOF'
{
  "name": "Users role for group is Guest",
  "description": "Checks the users role for a group is Guest or higher",
  "type": "js",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "code": "var ctx = $evaluation.getContext();\nvar ctxAttr = ctx.getAttributes();\nvar validRoles = {\n    owner: 1,\n    maintainer: 1,\n    developer: 1,\n    reporter: 1,\n    guest: 1,\n};\n\nif (!ctxAttr.exists('userGroupRole')) {\n    $evaluation.deny();\n} else {\n    var groupRole = ctxAttr.getValue('userGroupRole').asString(0);\n\n    if (validRoles[groupRole.toLowerCase()]) {\n        $evaluation.grant();\n    } else {\n        $evaluation.deny();\n    }\n}"
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/policy/js --config $CONFIG_PATH -r lagoon -f - <<'EOF'
{
  "name": "Users role for group is Maintainer",
  "description": "Checks the users role for a group is Maintainer or higher",
  "type": "js",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "code": "var ctx = $evaluation.getContext();\nvar ctxAttr = ctx.getAttributes();\nvar validRoles = {\n    owner: 1,\n    maintainer: 1,\n    developer: 0,\n    reporter: 0,\n    guest: 0,\n};\n\nif (!ctxAttr.exists('userGroupRole')) {\n    $evaluation.deny();\n} else {\n    var groupRole = ctxAttr.getValue('userGroupRole').asString(0);\n\n    if (validRoles[groupRole.toLowerCase()]) {\n        $evaluation.grant();\n    } else {\n        $evaluation.deny();\n    }\n}"
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/policy/js --config $CONFIG_PATH -r lagoon -f - <<'EOF'
{
  "name": "Users role for project is Guest",
  "description": "Checks the users role for a project is Guest or higher",
  "type": "js",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "code": "var ctx = $evaluation.getContext();\nvar ctxAttr = ctx.getAttributes();\nvar validRoles = {\n    owner: 1,\n    maintainer: 1,\n    developer: 1,\n    reporter: 1,\n    guest: 1,\n};\n\nif (!ctxAttr.exists('userProjectRole')) {\n    $evaluation.deny();\n} else {\n    var groupRole = ctxAttr.getValue('userProjectRole').asString(0);\n\n    if (validRoles[groupRole.toLowerCase()]) {\n        $evaluation.grant();\n    } else {\n        $evaluation.deny();\n    }\n}"
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/policy/js --config $CONFIG_PATH -r lagoon -f - <<'EOF'
{
  "name": "Users role for project is Maintainer",
  "description": "Checks the users role for a project is Maintainer or higher",
  "type": "js",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "code": "var ctx = $evaluation.getContext();\nvar ctxAttr = ctx.getAttributes();\nvar validRoles = {\n    owner: 1,\n    maintainer: 1,\n    developer: 0,\n    reporter: 0,\n    guest: 0,\n};\n\nif (!ctxAttr.exists('userProjectRole')) {\n    $evaluation.deny();\n} else {\n    var groupRole = ctxAttr.getValue('userProjectRole').asString(0);\n\n    if (validRoles[groupRole.toLowerCase()]) {\n        $evaluation.grant();\n    } else {\n        $evaluation.deny();\n    }\n}"
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/policy/js --config $CONFIG_PATH -r lagoon -f - <<'EOF'
{
  "name": "Users role for group is Reporter",
  "description": "Checks the users role for a group is Reporter or higher",
  "type": "js",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "code": "var ctx = $evaluation.getContext();\nvar ctxAttr = ctx.getAttributes();\nvar validRoles = {\n    owner: 1,\n    maintainer: 1,\n    developer: 1,\n    reporter: 1,\n    guest: 0,\n};\n\nif (!ctxAttr.exists('userGroupRole')) {\n    $evaluation.deny();\n} else {\n    var groupRole = ctxAttr.getValue('userGroupRole').asString(0);\n\n    if (validRoles[groupRole.toLowerCase()]) {\n        $evaluation.grant();\n    } else {\n        $evaluation.deny();\n    }\n}"
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/policy/js --config $CONFIG_PATH -r lagoon -f - <<'EOF'
{
  "name": "Users role for group is Owner",
  "description": "Checks the users role for a group is Owner or higher",
  "type": "js",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "code": "var ctx = $evaluation.getContext();\nvar ctxAttr = ctx.getAttributes();\nvar validRoles = {\n    owner: 1,\n    maintainer: 0,\n    developer: 0,\n    reporter: 0,\n    guest: 0,\n};\n\nif (!ctxAttr.exists('userGroupRole')) {\n    $evaluation.deny();\n} else {\n    var groupRole = ctxAttr.getValue('userGroupRole').asString(0);\n\n    if (validRoles[groupRole.toLowerCase()]) {\n        $evaluation.grant();\n    } else {\n        $evaluation.deny();\n    }\n}"
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/policy/js --config $CONFIG_PATH -r lagoon -f - <<'EOF'
{
  "name": "Users role for project is Owner",
  "description": "Checks the users role for a project is Owner or higher",
  "type": "js",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "code": "var ctx = $evaluation.getContext();\nvar ctxAttr = ctx.getAttributes();\nvar validRoles = {\n    owner: 1,\n    maintainer: 0,\n    developer: 0,\n    reporter: 0,\n    guest: 0,\n};\n\nif (!ctxAttr.exists('userProjectRole')) {\n    $evaluation.deny();\n} else {\n    var groupRole = ctxAttr.getValue('userProjectRole').asString(0);\n\n    if (validRoles[groupRole.toLowerCase()]) {\n        $evaluation.grant();\n    } else {\n        $evaluation.deny();\n    }\n}"
}
EOF

    #Authorization permissions
    echo Creating api authz permissions
    DEFAULT_PERMISSION_ID=$(/opt/jboss/keycloak/bin/kcadm.sh get -r lagoon clients/$CLIENT_ID/authz/resource-server/permission?name=Default+Permission --config $CONFIG_PATH | python -c 'import sys, json; print json.load(sys.stdin)[0]["id"]')
    /opt/jboss/keycloak/bin/kcadm.sh delete -r lagoon clients/$CLIENT_ID/authz/resource-server/permission/$DEFAULT_PERMISSION_ID --config $CONFIG_PATH
    echo '{"type":"resource","logic":"POSITIVE","decisionStrategy":"UNANIMOUS","name":"Admins Allowed Permission","description":"Admins granted access to all resources/scopes","resourceType":"urn:api:resources:default","policies":["Admin Role Policy"]}' | /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/resource --config $CONFIG_PATH -r lagoon -f -


    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "View Task",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["task"],
  "scopes": ["view"],
  "policies": ["User has access to project","Users role for project is Guest"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "View Environment Variable for Development Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["env_var"],
  "scopes": ["environment:view","type:development"],
  "policies": ["Users role for project is Developer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Update Task",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["task"],
  "scopes": ["update"],
  "policies": ["Users role for project is Developer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Add Environment Variable to Production Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["env_var"],
  "scopes": ["environment:add","type:production"],
  "policies": ["Users role for project is Maintainer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Delete Development Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["environment"],
  "scopes": ["delete","type:development"],
  "policies": ["Users role for project is Developer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Delete Backup",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["backup"],
  "scopes": ["delete"],
  "policies": ["Users role for project is Maintainer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Run Drush sql-sync from Any Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["task"],
  "scopes": ["task:source","type:production","drushSqlSync","type:development"],
  "policies": ["Users role for project is Developer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Update Group",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["group"],
  "scopes": ["update"],
  "policies": ["Users role for group is Maintainer"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Add Environment Variable to Development Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["env_var"],
  "scopes": ["environment:add","type:development"],
  "policies": ["Users role for project is Developer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "View Backups",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["backup"],
  "scopes": ["view"],
  "policies": ["Users role for project is Developer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Update Restore",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["restore"],
  "scopes": ["update"],
  "policies": ["User has access to project","Users role for project is Guest"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Add Deployment to Production Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["environment"],
  "scopes": ["type:production","deploy"],
  "policies": ["Users role for project is Maintainer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Add or Update Production Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["environment"],
  "scopes": ["type:production","addOrUpdate"],
  "policies": ["Users role for project is Maintainer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Delete All Backups",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["backup"],
  "scopes": ["deleteAll"],
  "policies": ["Admin Role Policy"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "View Deployments",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["deployment"],
  "scopes": ["view"],
  "policies": ["User has access to project","Users role for project is Guest"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Add User",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["user"],
  "scopes": ["add"],
  "policies": ["Default Policy"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Add or Update Development Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["environment"],
  "scopes": ["type:development","addOrUpdate"],
  "policies": ["Users role for project is Developer","User has access to project"]
}
EOF


    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "View Notification",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["notification"],
  "scopes": ["view"],
  "policies": ["Users role for project is Developer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "View All Projects",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["project"],
  "scopes": ["viewAll"],
  "policies": ["Admin Role Policy"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Delete Production Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["environment"],
  "scopes": ["type:production","delete"],
  "policies": ["Users role for project is Owner","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Add Notification to Project",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["project"],
  "scopes": ["addNotification"],
  "policies": ["User has access to project","Users role for project is Maintainer"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Delete Task",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["task"],
  "scopes": ["delete"],
  "policies": ["Users role for project is Developer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "View Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["environment"],
  "scopes": ["view"],
  "policies": ["User has access to project","Users role for project is Guest"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Add Group",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["group"],
  "scopes": ["add"],
  "policies": ["Default Policy"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "View Environment Variable for Project",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["env_var"],
  "scopes": ["project:view"],
  "policies": ["Users role for project is Maintainer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "View Project Private Key",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["project"],
  "scopes": ["viewPrivateKey"],
  "policies": ["User has access to project","Users role for project is Owner"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Delete All Groups",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["group"],
  "scopes": ["deleteAll"],
  "policies": ["Admin Role Policy"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Delete All Users",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["user"],
  "scopes": ["deleteAll"],
  "policies": ["Admin Role Policy"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Manage Openshift",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["openshift"],
  "scopes": ["viewAll","delete","update","deleteAll","add"],
  "policies": ["Admin Role Policy"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Delete SSH Key",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["ssh_key"],
  "scopes": ["delete"],
  "policies": ["User has access to own data"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Add Environment Variable to Project",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["env_var"],
  "scopes": ["project:add"],
  "policies": ["Users role for project is Owner","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Add Project",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["project"],
  "scopes": ["add"],
  "policies": ["Default Policy"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Get SSH Keys for User",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["ssh_key"],
  "scopes": ["view:user"],
  "policies": ["User has access to own data"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "View Openshift",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["openshift"],
  "scopes": ["view"],
  "policies": ["User has access to project","Users role for project is Maintainer"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Run Drush rsync from Any Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["task"],
  "scopes": ["task:source","type:production","drushRsync","type:development"],
  "policies": ["Users role for project is Developer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Delete All SSH Keys",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["ssh_key"],
  "scopes": ["removeAll","delete"],
  "policies": ["Admin Role Policy"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "View Environment Metrics",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["environment"],
  "scopes": ["storage"],
  "policies": ["Admin Role Policy"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Run Drush sql-sync to Development Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["task"],
  "scopes": ["drushSqlSync","task:destination","type:development"],
  "policies": ["Users role for project is Developer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Run Drush cache-clear",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["task"],
  "scopes": ["type:production","type:development","drushCacheClear"],
  "policies": ["User has access to project","Users role for project is Guest"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Add User to Group",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["group"],
  "scopes": ["addUser"],
  "policies": ["Users role for group is Maintainer"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Add Backup",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["backup"],
  "scopes": ["add"],
  "policies": ["Users role for project is Developer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Run Drush sql-sync to Production Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["task"],
  "scopes": ["type:production","drushSqlSync","task:destination"],
  "policies": ["User has access to project","Users role for project is Maintainer"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Update Production Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["environment"],
  "scopes": ["type:production","update"],
  "policies": ["Users role for project is Maintainer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Run Drush rsync to Development Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["task"],
  "scopes": ["drushRsync","task:destination","type:development"],
  "policies": ["Users role for project is Developer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Update SSH Key",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["ssh_key"],
  "scopes": ["update"],
  "policies": ["User has access to own data"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Add Task to Production Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["task"],
  "scopes": ["type:production","add"],
  "policies": ["Users role for project is Maintainer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Add Task to Development Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["task"],
  "scopes": ["type:development","add"],
  "policies": ["Users role for project is Developer","User has access to project"]
}
EOF


    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Add SSH Key",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["ssh_key"],
  "scopes": ["add"],
  "policies": ["User has access to own data"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "CUD Notification",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["notification"],
  "scopes": ["removeAll","delete","update","deleteAll","add"],
  "policies": ["Admin Role Policy"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Add Groups to Project",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["project"],
  "scopes": ["addGroup"],
  "policies": ["User has access to project","Users role for project is Maintainer"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Add Deployment to Development Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["environment"],
  "scopes": ["type:development","deploy"],
  "policies": ["Users role for project is Developer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Delete All Environments",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["environment"],
  "scopes": ["deleteAll"],
  "policies": ["Admin Role Policy"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Update Deployment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["environment"],
  "scopes": ["update"],
  "policies": ["Users role for project is Maintainer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Update Project",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["project"],
  "scopes": ["update"],
  "policies": ["User has access to project","Users role for project is Maintainer"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Remove Notification from Project",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["project"],
  "scopes": ["removeNotification"],
  "policies": ["User has access to project","Users role for project is Maintainer"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Delete User",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["user"],
  "scopes": ["delete"],
  "policies": ["User has access to own data"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Delete All Projects",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["project"],
  "scopes": ["deleteAll"],
  "policies": ["Admin Role Policy"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Remove User from Group",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["group"],
  "scopes": ["removeUser"],
  "policies": ["Users role for group is Maintainer"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "View Project",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["project"],
  "scopes": ["view"],
  "policies": ["User has access to project","Users role for project is Guest"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Delete Group",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["group"],
  "scopes": ["delete"],
  "policies": ["Users role for group is Maintainer"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Add Restore",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["restore"],
  "scopes": ["add"],
  "policies": ["User has access to project","Users role for project is Guest"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Run Drush archive-dump",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["task"],
  "scopes": ["drushArchiveDump","type:production","type:development"],
  "policies": ["Users role for project is Developer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Update User",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["user"],
  "scopes": ["update"],
  "policies": ["User has access to own data"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Delete Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["environment"],
  "scopes": ["delete"],
  "policies": ["User has access to project","Users role for project is Maintainer"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Deploy Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["environment"],
  "scopes": ["deploy"],
  "policies": ["Users role for project is Maintainer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Remove Groups from Project",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["project"],
  "scopes": ["removeGroup"],
  "policies": ["User has access to project","Users role for project is Maintainer"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Run Drush rsync to Production Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["task"],
  "scopes": ["type:production","drushRsync","task:destination"],
  "policies": ["User has access to project","Users role for project is Maintainer"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Run Drush sql-dump",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["task"],
  "scopes": ["type:production","type:development","drushSqlDump"],
  "policies": ["Users role for project is Developer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "View Environment Variable for Production Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["env_var"],
  "scopes": ["type:production","environment:view"],
  "policies": ["Users role for project is Maintainer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Delete Project",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["project"],
  "scopes": ["delete"],
  "policies": ["User has access to project","Users role for project is Owner"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Delete Environment Variable",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["env_var"],
  "scopes": ["delete"],
  "policies": ["Users role for project is Maintainer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Update Development Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["environment"],
  "scopes": ["update","type:development"],
  "policies": ["Users role for project is Developer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "User can SSH to Development Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["environment"],
  "scopes": ["ssh","type:development"],
  "policies": ["Users role for project is Developer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "User can SSH to Production Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["environment"],
  "scopes": ["ssh","type:development"],
  "policies": ["Users role for project is Maintainer","User has access to project"]
}
EOF


    # http://localhost:8088/auth/admin/realms/lagoon/clients/1329f641-a440-44a7-996f-ed1c560e2edd/authz/resource-server/permission/scope
    # {"type":"scope","logic":"POSITIVE","decisionStrategy":"UNANIMOUS","name":"Backup View","resources":["2ebb5852-6624-4dc6-8374-e1e54a7fd9c5"],"scopes":["8e78b877-f930-43ff-995f-c907af64f69f"],"policies":["d4fae4e2-ddc7-462c-b712-d68aaeb269e1"]}
}

function configure_keycloak {
    until is_keycloak_running; do
        echo Keycloak still not running, waiting 5 seconds
        sleep 5
    done

    # Set the config file path because $HOME/.keycloak/kcadm.config resolves to /opt/jboss/?/.keycloak/kcadm.config for some reason, causing it to fail
    CONFIG_PATH=/opt/jboss/keycloak/standalone/data/.keycloak/kcadm.config

    echo Keycloak is running, proceeding with configuration

    /opt/jboss/keycloak/bin/kcadm.sh config credentials --config $CONFIG_PATH --server http://localhost:8080/auth --user $KEYCLOAK_ADMIN_USER --password $KEYCLOAK_ADMIN_PASSWORD --realm master

    configure_lagoon_realm
    configure_api_client

    echo "Config of Keycloak done. Log in via admin user '$KEYCLOAK_ADMIN_USER' and password '$KEYCLOAK_ADMIN_PASSWORD'"
}

/opt/jboss/keycloak/bin/add-user-keycloak.sh --user $KEYCLOAK_ADMIN_USER --password $KEYCLOAK_ADMIN_PASSWORD
configure_keycloak &

/bin/sh /opt/jboss/tools/databases/change-database.sh mariadb

##################
# Start Keycloak #
##################

exec /opt/jboss/keycloak/bin/standalone.sh -b 0.0.0.0
