#!/bin/bash

# halt the script on an error
set -e

## In case of an error, print abortion
trap 'echo "Aborting due to error on line $LINENO. Exit code: $?" >&2' ERR

## Check if the user is logged into Azure, error out if not
if [ -z "$(az account show)" ]; then
	echo "You are not logged into Azure. Please run 'az login' before running this script."
	exit 1
fi

if [ -z "$GITHUB_REPOSITORY" ]; then
	echo "GITHUB_REPOSITORY is missing. Please enter it below:"
	read GITHUB_REPOSITORY
fi

# Check if GitHub Repository is of format <owner>/<repo>
if [[ ! $GITHUB_REPOSITORY =~ ^[a-z0-9-]+/[a-z0-9-]+$ ]]; then
	echo "GITHUB_REPOSITORY is not of format <owner>/<repo>. Exiting..."
	exit 1
fi

if [ -z "$AZ_SUBSCRIPTION_ID" ]; then
	echo "AZ_SUBSCRIPTION_ID is missing. Please enter it below:"
	read AZ_SUBSCRIPTION_ID
fi

##
# CREATE APP AND SERVICE PRINCIPAL
##
echo "Creating an App and Service Principal..."
AZURE_ADMIN_APP=$(az ad app create --display-name "GitHub Actions Workshop Administrator" --sign-in-audience "AzureADMyOrg")

APP_OBJECT_ID=$(echo $AZURE_ADMIN_APP | jq -r '.id')
APP_ID=$(echo $AZURE_ADMIN_APP | jq -r '.appId')

SERVICE_PRINCIPAL=$(az ad sp list --filter "appId eq '$APP_ID'")
if [ "$SERVICE_PRINCIPAL" == "[]" ]; then
	echo "Adding Servie Principal to App..."
	SERVICE_PRINCIPAL=$(az ad sp create --id $APP_ID) 
	SERVICE_PRINCIPAL_ID=$(echo $SERVICE_PRINCIPAL | jq -r '.id')
else
	echo "Service Principal already exists. Skipping..."
	SERVICE_PRINCIPAL_ID=$(echo $SERVICE_PRINCIPAL | jq -r '.[0].id')
fi

##
# GET THE ROLE ID OF THE AD ROLE "Cloud Application Administrator"
##
CLOUD_APPLICATION_ADMINISTRATOR_TEMPLATE_ID='158c047a-c907-4556-b7ef-446551a6b5f7'
CLOUD_APPLICATION_ADMINISTRATOR=$(az rest --method GET --uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions?\$filter=DisplayName eq 'Cloud Application Administrator'")
CLOUD_APPLICATION_ADMINISTRATOR_ID=$(echo $CLOUD_APPLICATION_ADMINISTRATOR | jq -r '.value[0].id')


##
# ASSIGN THE ROLE "Cloud Application Administrator" TO THE SERVICE PRINCIPAL IN THE SCOPE OF THE APP
##
ROLE_ASSIGNMENT_BODY=$(cat <<EOF
{
  "@odata.type": "#microsoft.graph.unifiedRoleAssignment",
  "principalId": "${SERVICE_PRINCIPAL_ID}",
  "roleDefinitionId": "${CLOUD_APPLICATION_ADMINISTRATOR_ID}",
  "directoryScopeId": "/"
}
EOF
)

ROLE_ASSIGNMENT=$(az rest --method GET --uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?\$filter=principalId eq '${SERVICE_PRINCIPAL_ID}' and roleDefinitionId eq '${CLOUD_APPLICATION_ADMINISTRATOR_ID}' and directoryScopeId eq '/'")
ROLE_ASSIGNMENT_VALUE=$(echo $ROLE_ASSIGNMENT | jq -r '.value')

## If ROLE_ASSIGNMENT.value is [], then the Role Assignment does not exist
if [ "$ROLE_ASSIGNMENT_VALUE" == "[]" ]; then
  echo "Assigning Role with Id ${CLOUD_APPLICATION_ADMINISTRATOR_ID} to Service Principal ${SERVICE_PRINCIPAL_ID} in the Scope of the App with ObjectId ${APP_OBJECT_ID}..."
  az rest --method POST --uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments" --body "$ROLE_ASSIGNMENT_BODY" --headers "Content-Type=application/json"
else
  echo "Role Assignment already exists. Skipping..."
fi

##
# CREATE FEDERATED CREDENTIALS FOR OIDCS ACCESS OF THE REPOSITORY
##
OIDC_JSON_BODY=$(cat <<EOF
{
	"name": "app-registration-credentials",
	"issuer": "https://token.actions.githubusercontent.com",
	"subject": "repo:${GITHUB_REPOSITORY}:branch:main", 
	"description": "These credentials allow actions of the main branch to create new App Registration and Service-principals as part of the GitHub Actions Workshop (https://github.com/actions-workshop/actions-workshop)",
	"audiences": [
		"api://AzureADTokenExchange"
	]
}
EOF
)

EXISTING_FC=$(az ad app federated-credential list --id $APP_ID --query "[?name=='app-registration-credentials']")
if [ "$EXISTING_FC" == "[]" ]; then
	echo "Creating OIDC Acceess through federated credentials for the $GITHUB_REPOSITORY..."
	az ad app federated-credential create --id ${APP_ID} --parameters "$OIDC_JSON_BODY"
else 
	echo "Federated credential already exists. Skipping..."
fi



##
# CREATE A CUSTOM ROLE FOR THE WORKSHOP PARTICIPANTS TO BE ABLE TO DEPLOY WEB APPS
##
ROLE_JSON=$(cat <<EOF
{
	"Name": "GitHub Actions Workshop Role",
	"Description": "This role is used by the GitHub Actions Workshop to allow a Deployment in Azure Web Apps.",
	"Actions": [
		"Microsoft.Resources/subscriptions/resourceGroups/read",
		"Microsoft.Resources/subscriptions/resourceGroups/write",
		"Microsoft.Web/serverfarms/Read",
		"Microsoft.Web/serverfarms/Write",
		"Microsoft.Resources/deployments/validate/action",
		"Microsoft.Web/sites/Write",
		"Microsoft.Web/sites/Read",
		"Microsoft.Resources/deployments/write",
		"Microsoft.Resources/deployments/read",
		"Microsoft.Resources/deployments/operationstatuses/read"
	],
	"AssignableScopes": ["/subscriptions/$AZ_SUBSCRIPTION_ID"]
}
EOF
)

EXISTING_ROLE=$(az role definition list --custom-role-only --query "[?roleName=='GitHub Actions Workshop Role']")

if [ "$EXISTING_ROLE" == "[]" ]; then
	echo "Creating Custom Role..."
	az role definition create --role-definition "$ROLE_JSON" --only-show-errors
else
	echo "Custom Role already exists. Skipping..."
fi

echo ""
echo "Azure Account Preparation was succesfull.
The following resources were created:
  - An App Registration and Service Principal with the name of 'GitHub Actions Workshop Administrator' (from the portal, you can find it in Entra Id under App registrations -> All applications) and the role 'Cloud Application Administrator' assigned to it
  - Federated Credentials for OIDC Access for the App Registration from https://github.com/${GITHUB_REPOSITORY} which allows the issue ops actions to create new AD App Registrations and Service Principals
  - A Custom Role with the name 'GitHub Actions Workshop Role' (from the portal, you can find it under your Subscription -> IAM -> Roles) to be used by issue ops for the participant's created Service Principals
"

echo "Here are the required ids for:
  AZ_CLIENT_ID:       $(echo $AZURE_ADMIN_APP | jq -r .appId)
  AZ_TENANT_ID:       $(echo $SERVICE_PRINCIPAL | jq -r .[0].appOwnerOrganizationId)
  AZ_SUBSCRIPTION_ID: $AZ_SUBSCRIPTION_ID
Use these to create Secrets in your Repository https://github.com/$GITHUB_REPOSITORY!
"
