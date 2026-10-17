# Balsoft Data Refresh (BDR)

A Dynamics 365 Finance and Operations model that prepares an environment after an LCS
database refresh or a Power Platform admin center copy.

After a copy, Microsoft disables every user except Admin, puts all batch jobs on hold,
removes business event endpoints and clears or skips several settings. Microsoft's guidance
for the step after that is a data package and manual work. Database refresh does that work
for you, per environment, and logs every step.

In Finance and Operations the feature is called **Database refresh**. It has its own module
in the navigation (Workspaces, Periodic tasks, Inquiries, Setup) and a workspace tile under
System administration > Workspaces.

## What it does

| Task | What it does | Standard after a copy |
|---|---|---|
| Enable users | Enables the users listed for the environment; every other user keeps its state | All users except Admin disabled |
| Assign security roles | Assigns roles per environment, by AOT name | Roles copied from the source |
| Cancel pending workflows | Cancels the pending workflow instances of the listed workflows (or all) in all or in selected companies | Instances stay pending |
| Set field values | Writes any value into any table field per environment, in all or in selected companies (URLs, e-mail settings including the SMTP password, integration settings) | Manual or data package |
| Create business event endpoints | Creates endpoints of every Azure type and activates their business events | Endpoints removed |
| Release batch jobs | Puts the listed batch jobs back to Waiting | All batch jobs on hold |
| Clean up data | Deletes records older than N days per table, or empties a table, in all or in selected companies | Transactionless copy (PPAC only, all transactions) |

Tasks run in the sequence set per environment. A failed task does not stop the job unless
**Stop on first error** is set. Every run is recorded as a job with task results and messages.
Finished jobs older than **Keep job history (days)** are deleted when a new job starts. A running
or scheduled job cannot be deleted, because it still blocks new jobs of its environment.

## How it is built

The model follows the structure of Microsoft's archive feature (`ArchiveService`):

- **Task types are plugins.** Each task implements `BDRITaskType` and is found through
  `SysPluginFactory`. `BDRTaskTypeRegistration` writes them into `BDRTaskType` automatically
  when the setup forms open. Add your own task in your own model, no change to BDR needed.
- **Jobs.** `BDRJobProcessor` runs the active tasks of the environment and writes
  `BDRJobHistory`, `BDRTaskHistory` and `BDRMessageLog`.
- **Workspace.** `BDRWorkspace` shows the jobs, the tasks of the selected job and the messages of
  the selected task. **Show all messages of the job** lists the messages of every task and of the
  job itself. Each message refers to its job and its task (`BDRMessageLog.TaskHistory`).
- **Security.** Duties `BDRWorkspaceView` and `BDRWorkspaceMaintain`, role `BDRAdministrator`.

The setup tables hold the configuration of every environment and are maintained in
production, so each copy brings the configuration of all environments with it.

Environments are identified the way Microsoft does it in the monitoring and telemetry
parameters (`SysEnvironmentModeMap`): by environment ID and environment mode (`EnvironmentMode`:
Development, Test, Production). The ID is the Power Platform environment ID of a unified
environment or the LCS environment ID of an LCS environment, read from
`EnvironmentFactory::GetApplicationEnvironment()` (`Infrastructure.BapEnvironmentId`,
`LCS.LCSEnvironmentId`).

### Safety

- Database refresh never runs in an environment with the mode Production. The check is in the
  job itself, so it also applies to the service.
- It only runs when the current instance is set up as an environment, and an environment passed
  to the service must have the environment ID of the current instance.
- Secrets (endpoint client secrets, storage keys) are never stored. A setup row names a secret,
  the pipeline passes the value with the service call, and it is used for that run only.
- Data cleanup only accepts transaction, worksheet, staging and miscellaneous tables.
- Enable users and Cancel pending workflows only act on what is set up for the environment: the
  listed users, and the listed workflows in the chosen companies. Without setup they change nothing.
- A service call runs the tasks after a batch task (data cleanup) in batch, without the secrets
  of the call. A task that needs a pipeline secret (field values with a secret, business event
  endpoints) after such a task is refused before the job starts.

## Download

Every [release](https://github.com/balsoft-gmbh/d365fo-database-refresh/releases) has two deployable
packages, built from the tagged source by the release workflow:

- `BalsoftDataRefresh-<version>-LCS.zip`: upload it to the Asset library in Lifecycle Services and
  apply it to the environment.
- `BalsoftDataRefresh-<version>-Unified.zip`: for unified environments in the Power Platform admin
  center. Unzip it and run `pac package deploy --package TemplatePackage.dll` against the environment.

To compile the model in your own pipeline, start from `Pipelines/bdr-build.yml`.

## Setup

1. Deploy the model and assign the role **Database refresh administrator**.
2. Open **Database refresh > Setup > Environments**. Add production with the mode Production,
   then each environment that receives copies with its environment ID (Power Platform admin
   center > environment > Environment ID, or LCS) and the mode Test or Development.
   In an environment itself, **Add current environment** fills in its ID.
3. Add the tasks the environment needs (**Add task**, or **Add all tasks**), switch them on and set the sequence.
   The environments and the tasks of the selected environment are two grids of the same width.
4. Select a task and **Set up** to open its setup for this environment: users to enable,
   security roles, workflows to cancel, field values (with table and field lookups), business
   event endpoints, batch jobs to release, data cleanup rules.

5. **Copy setup** copies the tasks and their setup, with the companies of every row, from the
   selected environment to another environment. Every copied row and company is checked like a
   row entered by hand; rows that break a rule of the target (for example Truncate next to another
   cleanup rule of the table, or overlapping companies) are refused and named in the messages.

Do the setup in production. The next copy brings it to every environment.

### Companies

The setup tables are shared by all companies. Each field value, business event, workflow to
cancel and cleanup rule has **All companies**. Turn it off and use **Companies** in the toolbar to choose the
companies of that row (Add all companies, then delete the ones that should not get the
change). The grid shows the chosen companies, for example `DEMF, USMF`. A row without any
company is skipped with a warning in the job log. Companies cannot be chosen where they do
not apply: for shared tables (processed once) and for **Truncate table**, which always
empties the whole table. Days to keep only apply to Delete older records, and Has value
only to a row with Only where field.

### Field values

One grid with table, field, **Value to write**, and optionally **Only where field** and
**Has value**. Without a key field the value is written to all records of the table, which is
what parameter tables need. With a key field only the matching records are updated.
**Pipeline secret name** is only for sensitive values: it matches an entry in `Secrets` in the
service request, and Value to write stays empty.

Encrypted fields, such as `SysEmailSMTPPassword.Password` (the SMTP password in Email parameters),
take their value only from a pipeline secret. The task writes it through the standard encryption,
like the Email parameters form does, so the value works in the refreshed environment. A refresh
clears these fields because the source environment's encryption cannot be read on the target.

A row is checked when it is saved, so it cannot fail later during a refresh: the table must store
data (no temporary table, view, map or system table), the field must not be a system field
(RecId, DataAreaId and the like), the field type must be text, number, date, date and time, GUID,
enum or encrypted (also for a row with a pipeline secret), and Value to write and Has value must
fit their field types. An enum takes its name or number; an empty value is only valid for a field that accepts it.
A row that still fails during a refresh, for example because a secret is missing or its value
does not fit an enum field, fails the task, and the other rows are still written.

### Data cleanup

One grid with table, mode, days to keep, **Delete related records**, active, All companies and
Companies. Three modes:

- **Delete older records** deletes records created more than the days to keep ago (at least 1
  day), in all or in the chosen companies. The table needs a CreatedDateTime field.
- **Delete all records** deletes every record of the table in all or in the chosen companies.
- **Truncate table** empties the whole table for all companies at once. It is the only rule a
  table can have.

A table can have a Delete older records and a Delete all records rule at the same time when
they cover different companies, for example delete all in USMF and older than 90 days in
GBPM. The table lookup only lists the table groups that may be cleaned up.

**Delete related records** (on by default) lets Delete older records and Delete all records
follow the table's delete actions, so related records (for example the lines of a journal) are
deleted with their headers. Turn it off for a faster delete when the related table has its own
rule. Truncate table never deletes related records: give the related tables their own rule.

### Security roles

Assign security roles resolves role labels from Microsoft role metadata, in both the lookup
and the saved row, while retaining the AOT role identifier for execution after a refresh.
Internal roles without a usable label display their identifier instead of a blank name.

### Business event endpoints

Two grids, like Microsoft's business event setup: the endpoints of the environment on top and
the business events of the selected endpoint below.

The action pane holds **New endpoint**, **Edit endpoint**, **Companies** and the standard
**Delete**; there is no standard New, because endpoints are only created in the dialog.
**New endpoint** opens a dialog: choose the endpoint type, select **Next**, then enter the
name, the connection fields of that type (queue, topic, hub or container, URL, SKU) and the
Key Vault authentication, and **OK**. The endpoint then appears in the grid. **Edit
endpoint** opens the same dialog for the selected endpoint. Endpoint names are fixed after
creation; deleting an endpoint removes its business events.

The companies belong to the endpoint, as in standard where business events are activated per
legal entity: **All companies**, or **Companies** to choose them. Below, add the business
events of the selected endpoint from the business event catalog; each is activated for that
endpoint in the endpoint's companies. Key Vault secret name identifies the connection secret in
the vault; Client secret name identifies the app credential supplied in the service request.

Endpoints are validated like Microsoft's endpoint setup:

- **Required fields per type**, as in Microsoft's endpoint tables: application ID, Key Vault
  DNS name, Key Vault secret name and client secret name for every type; the queue, topic, hub
  or container name for Service Bus, Event Hub and Blob storage; the URL for Event Grid.
- **Test event.** A new endpoint, or one whose connection fields changed, is only saved after
  `BusinessEventsEndpointManager::validateEndpoint` has read the Key Vault secret and sent a
  test event to the endpoint. Enter the client secret in **Client secret (to validate)**; it is
  used for this test only and not stored. At run time the client secret comes from the pipeline.

## Run it

- **Manually:** Database refresh > Periodic tasks > Run database refresh tasks. The dialog
  shows the setup for the current F&O instance and keeps it read-only. It does not reuse
  an environment from a previous run. A production environment is rejected.
- **From a pipeline after the copy:**

```http
POST https://contoso-uat.sandbox.operations.dynamics.com/api/services/BDRServices/BDRService/run
Authorization: Bearer <token for the environment URL>
Content-Type: application/json

{
  "_request": {
    "EnvironmentId": "UAT",
    "TaskTypeNames": [],
    "RequestId": "<pipeline run ID>",
    "RunInBatch": false,
    "ReturnResultOnFailure": false,
    "Secrets": [ { "Name": "ServiceBusAppSecret", "Value": "<from your pipeline secret store>" } ]
  }
}
```

| Request field | Meaning |
|---|---|
| `EnvironmentId` | Environment to run; empty for the current instance. It must be the current instance and not production. |
| `TaskTypeNames` | Tasks to run; empty for all active tasks. A name that is not an active task of the environment is rejected. |
| `RequestId` | Optional ID of the caller, for example the pipeline run ID. A repeated call with the same ID returns the job of the first call instead of running again, so a retry after a timeout is safe. |
| `RunInBatch` | Schedules all tasks in batch: the call returns at once with status `Scheduled`, and the pipeline polls `getJobStatus`. Secrets cannot be passed in this mode. |
| `ReturnResultOnFailure` | Returns the job result for a failed job instead of an error. |
| `Secrets` | Values referenced by name in the setup, for this run only; never stored. |

The result holds `JobId`, `EnvironmentId`, `RequestId`, `Status` (`Waiting`, `Running`,
`Scheduled`, `Succeeded`, `PartlySucceeded`, `Failed`), `Succeeded`, `Finished`, `Message` and
the result of each task (`TaskTypeName`, `Status`, `RecordsAffected`, `Message`).

A task that logs an error is marked failed, including endpoint validation errors. Stop on
first error also applies to tasks continued in batch. By default a failed job is returned as
an error (HTTP 500) that names the failed tasks, so a pipeline that checks the HTTP status does
not open the environment after a failed run. With `ReturnResultOnFailure` the pipeline gets the
result and checks `Succeeded`.

Long running tasks (data cleanup) are scheduled as a batch job, and the tasks after them follow
in the same batch job so the order is kept. They start once the environment leaves
administration mode. Poll with `getJobStatus` and `{"_request": {"JobId": 123}}`, or with
`{"_request": {"RequestId": "<pipeline run ID>"}}`, until `Finished` is true. An unknown job is
an error.

An environment runs one job at a time: a new job, from the service or the dialog, is refused
while another job of the environment is running or scheduled. A job older than **Running job
timeout (hours)** in the parameters (default 12) no longer blocks, for example after a restart.

The calling Entra ID application must be registered in Finance and Operations
(System administration > Setup > Microsoft Entra ID applications) with a user that has the
Database refresh administrator role.

## Automate the copy

`Pipelines/copy-and-refresh.yml` is a sample Azure DevOps pipeline that does the whole refresh:

1. **Copy**: copies the source environment (for example production) over the target sandbox with the
   Power Platform Build Tools task `PowerPlatformCopyEnvironment@2`, behind an approval on an Azure
   DevOps environment.
2. **Refresh**: runs `Pipelines/scripts/Invoke-DatabaseRefresh.ps1` against the target. The script waits
   until Finance and Operations answers, calls `run` with the pipeline run ID as `RequestId` and the
   secrets from the pipeline, polls `getJobStatus` while tasks continue in batch, prints every task and
   fails the pipeline if the job did not succeed.

Run it on demand, or uncomment the schedule for a weekly refresh. With **skipCopy** it only runs
Database refresh, for example after a copy started in the Power Platform admin center. The script also
works on its own:

```powershell
$env:BDR_CLIENT_SECRET = '<client secret>'
$env:BDR_SECRET_ServiceBusAppSecret = '<secret named in the setup>'
./Pipelines/scripts/Invoke-DatabaseRefresh.ps1 -FinOpsUrl https://contoso-uat.sandbox.operations.dynamics.com `
    -TenantId <tenant id> -ClientId <client id> -EnvironmentId UAT -SecretNames ServiceBusAppSecret
```

The comments at the top of the pipeline list what to create first: the service connection of the
source, the variable group `DatabaseRefresh` (ideally linked to Key Vault) and the Azure DevOps
environment with its approval.

## Repository

| Path | Content |
|---|---|
| `Metadata/BDR` | The model (AOT XML) |
| `Projects/BalsoftDataRefresh` | Visual Studio solution and project |
| `Pipelines/bdr-build.yml` | Build on a Microsoft-hosted agent, produces the deployable and the Power Platform unified package |
| `Pipelines/bdr-release.yml` | Deploys the unified package of the latest build to a Power Platform environment through a service connection |
| `Pipelines/copy-and-refresh.yml` | Sample: copy an environment, then run Database refresh on the copy through the service |
| `Pipelines/scripts/Invoke-DatabaseRefresh.ps1` | Calls the service, waits for the job and fails on errors; used by the sample pipeline |
| `.github/workflows/release.yml` | GitHub Actions: builds main and publishes a release with both deployable packages |
| `.github/scripts/New-DeployablePackages.ps1` | Creates the two deployable packages from the compiler output; used by the release workflow |

## License

MIT, see [LICENSE](LICENSE). Use it, change it, share it.

Balsoft GmbH, Cologne. https://balsoft.de
