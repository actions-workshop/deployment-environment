# deployment-environment

This is repository contains actions to allow the automatic creation of Azure Web App deployment environments. It is supposed to be used by a Trainer of the [GitHub Actions Workshop](https://github.com/actions-workshop/actions-workshop) to allow participants to deploy during the workshop without requiring their own Azure account.

The main idea is that participants of the workshop:

1. open up an issue from an issue-form in this repository giving their target repository
2. A workflow is triggered that
    1. creates the deployment environment (basically a resource group) in Azure
    2. creates an App Registratoin with a Service Principal that allows the repository to deploy via OIDC
    3. writes the necessary information into the target repository's action variables

## How it works in Detail

```mermaid
graph TD;
    A[Issue Opened] --> B(Trigger `Handle Env Request`);
    B --> C[Verify Repository Exists];
    C --> E[Update Issue `In Progres`];
    C --> D(Trigger `Create Deployment Environment`);
    D --> F[Create Service Principal];
    F --> G[Create Federated Credentials];
    G --> H[Create Resource Group];
    H --> I[Assign Role to Service Principal];
    I --> J[Write Variables to Target Repository];
    J --> K[Update Issue `Done`];
```

1. There is an [Issue-Template](./github/ISSUE_TEMPLATE/create-deployment-environment.md) that contains an issue-form to ask for the target repository from which the deployment is supposed to be triggered.
2. Opening this issue triggers the [Handle Env Request](./.github/workflows/handle-env-request.yml) workflow, which:
   1. Verifies that the target repository exists
   2. Puts the given information into the correct format
   3. Triggers the downstream [Create Deployment Environment](./.github/workflows/create-deployment-environment.yml) workflow
   4. Creates a comment on the issue with thente status of the deployment environment creation
3. The triggered [Create Deployment Environment](./.github/workflows/create-deployment-environment.yml) then executes several steps on Azure:
   1. It creates an **Azure AD Subscription** with a **Service Principal**
   2. It creates **Federated Credentials for OIDC Access** from the given repository and the `Staging` Environment
   3. It creates a **ResourceGroup** in Azure that acts as target for the deployment
   4. It assigns a **Role** that contains all permissions to deploy a Azure Web App to the Service Principal for the given ReosourceGroup
   5. It writes the variables `AZ_RESOURCE_GROUP` and the `AZ_CLIENT_ID` into the repositorie's action variables

Once done, the participants can use the `deploy` workflow in their repository to deploy to the created environment.
