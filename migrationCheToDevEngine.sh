#!/bin/bash

# scale che-server to zero and postgre too.
NAMESPACE="eclipse-che"
clusterName="eclipse-che"
# Keycloak admin name
keycloakAdmin=admin
realm="che"

identityURL=$(oc get checluster "${clusterName}" -n "${NAMESPACE}" -o jsonpath="{.status.keycloakURL}" )
echo "[INFO] Identity url is: '${identityURL}'"
identitySecretName=$(oc get checluster "${clusterName}" -n "${NAMESPACE}" -o jsonpath="{.spec.auth.identityProviderSecret}")
echo "[INFO] Secret with identity auth info is: '${identitySecretName}'"
password=$(oc get secret "${identitySecretName}" -n "${NAMESPACE}" -o jsonpath="{.data.password}" | base64 -d)

# Get admin token to retrieve users information.
updateToken() {
    TOKEN=$(curl -k \
    -d "client_id=admin-cli" \
    -d "username=${keycloakAdmin}" \
    -d "password=${password}" \
    -d "grant_type=password" \
    "${identityURL}/realms/master/protocol/openid-connect/token" | jq -r ".access_token")
}

updateToken

userIds=($(curl -k -H "Authorization: bearer ${TOKEN}" "${identityURL}/${keycloakAdmin}/realms/${realm}/users" | jq ".[] | .id" | tr "\r\n" " "))

usersIdToMigrate=""
for userId in "${userIds[@]}"; do
    updateToken

    userId=$(echo "${userId}" | tr -d "\"")
    echo "${userId}"
    echo "${identityURL}/${keycloakAdmin}/realms/${realm}/users/${userId}/federated-identity"
    userFederation=$(curl -k -H "Authorization: bearer ${TOKEN}" "${identityURL}/${keycloakAdmin}/realms/${realm}/users/${userId}/federated-identity")
    provider=$(echo "${userFederation}" | jq -r ".[] | select(.identityProvider == \"openshift-v4\")")
    if [ -n "${provider}" ]; then
        openshiftUserId=$(echo "${provider}" | jq ".userId" | tr -d "\"")
        usersIdToMigrate="${usersIdToMigrate} ${userId}@${openshiftUserId}"
    fi
done

echo "[INFO] Migration stuff: ${usersIdToMigrate}"

# check that postgre is non external
postgreImage=$(kubectl get deployment postgres -n "${NAMESPACE}" -o jsonpath="{.spec.template.spec.containers[0].image}")
podIP=$(oc get pod -l component=postgres -n "${NAMESPACE}" -o jsonpath="{.items[0].status.podIP}")

cat <<EOF | oc apply -n "${NAMESPACE}" -f -
kind: Job
apiVersion: batch/v1
metadata:
  name: migrate-users-db
spec:
  parallelism: 1
  completions: 1
  backoffLimit: 6
  template:
    metadata:
      name: migrate-users-db
    spec:
      volumes:
        - name: postgres-data
          persistentVolumeClaim:
            claimName: postgres-data
      containers:
        - name: postgre
          image: >-
            ${postgreImage}
          env:
            - name: POSTGRESQL_USER
              valueFrom:
                secretKeyRef:
                  name: che-postgres-secret
                  key: user
            - name: POSTGRESQL_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: che-postgres-secret
                  key: password
            - name: USER_IDS_TO_MIGRATE
              value: "${usersIdToMigrate}"
            - name: POSTGRESQL_POD_IP
              value: "${podIP}"
          command:
            - /bin/bash
          args: 
            - "-c"
            - >-
              DUMP_FILE="/tmp/dbdump.sql";
              DB_NAME="dbche";
              DB_OWNER="pgche";
              touch "\${DUMP_FILE}";
              echo "[INFO] Create database dump: \${DUMP_FILE}";
              export PGPASSWORD="\$(POSTGRESQL_PASSWORD)";
              pg_dump -d \${DB_NAME} -h \$(POSTGRESQL_POD_IP) -U \$(POSTGRESQL_USER) > "\${DUMP_FILE}";

              userMappings=(\$(USER_IDS_TO_MIGRATE));
              echo "[INFO] Mappings array is:  \${userMappings[@]}";

              for userIdMapping in "\${userMappings[@]}"; do
                currentUserId=\${userIdMapping%@*}
                openshiftUserId=\${userIdMapping#*@}
                echo "[INFO] Replace \${currentUserId} to \${openshiftUserId} in the dump."
                sed -i "s|\${currentUserId}|\${openshiftUserId}|g" "\${DUMP_FILE}"
              done;

              echo "[INFO] Replace database dump...";

              echo "[INFO] Set up connection limit: 0";
              psql -h \$(POSTGRESQL_POD_IP) -U \$(POSTGRESQL_USER) -q -d template1 -c "ALTER DATABASE \${DB_NAME} CONNECTION LIMIT 0;";

              echo "Disconnect database: '\${DB_NAME}'";
              psql -h \$(POSTGRESQL_POD_IP) -U \$(POSTGRESQL_USER) -q -d template1 -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '\${DB_NAME}';";

              echo "Drop database... '\${DB_NAME}'";
              psql -h \$(POSTGRESQL_POD_IP) -U \$(POSTGRESQL_USER) -q -d template1 -c "DROP DATABASE \${DB_NAME};";

              echo "[INFO] Create an empty database '\${DB_NAME}'";
              createdb -h \${POSTGRESQL_POD_IP} -U \${POSTGRESQL_USER} "\${DB_NAME}" --owner="\${DB_OWNER}";

              echo "[INFO] Apply database dump.";
              psql -h \${POSTGRESQL_POD_IP} -U \${POSTGRESQL_USER} "\${DB_NAME}" < "\${DUMP_FILE}";
              echo "done!";

              rm -f "\${DUMP_FILE}";
          imagePullPolicy: IfNotPresent
          volumeMounts:
            - name: postgres-data
              mountPath: /var/lib/pgsql/data
          securityContext:
            capabilities:
              drop:
                - ALL
                - KILL
                - MKNOD
                - SETGID
                - SETUID
            # runAsUser: 1000620000
      terminationMessagePolicy: File
      restartPolicy: OnFailure
      terminationGracePeriodSeconds: 30
      dnsPolicy: ClusterFirst
      schedulerName: default-scheduler
EOF
