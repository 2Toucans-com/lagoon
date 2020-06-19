// @flow

/* ::
import type MariaSQL from 'mariasql';
*/

const harborClient = require('../../clients/harborClient');
const logger = require('../../logger');
const R = require('ramda');
const Sql = require('../env-variables/sql');
const { isPatchEmpty, prepare, query, whereAnd } = require('../../util/db');

const lagoonHarborRoute = R.compose(
  R.defaultTo('http://172.17.0.1:8084'),
  R.find(R.test(/harbor-nginx/)),
  R.split(','),
  R.propOr('', 'LAGOON_ROUTES'),
)(process.env);

const lagoonWebhookAddress = R.compose(
  R.defaultTo('http://webhook-handler:3000'),
  R.find(R.test(/webhook-handler/)),
  R.split(','),
  R.propOr('', 'LAGOON_ROUTES'),
)(process.env);

const createHarborOperations = (sqlClient /* : MariaSQL */) => ({
  addProject: async (lagoonProjectName, projectID) => {
    // Create harbor project
    try {
      var res = await harborClient.post(`projects`, {
        body: {
          count_limit: -1,
          project_name: lagoonProjectName,
          storage_limit: -1,
          metadata: {
            auto_scan: "true",
            reuse_sys_cve_whitelist: "true",
            public: "false"
          }
        }
      });
      logger.debug(`Harbor project ${lagoonProjectName} created!`)
    } catch (err) {
      // 409 means project already exists
      // 201 means project created successfully
      if (err.statusCode == 409) {
        logger.info(`Unable to create the harbor project "${lagoonProjectName}", as it already exists in harbor!`)
      } else {
        console.log(res)
        logger.error(`Unable to create the harbor project "${lagoonProjectName}", error: ${err}`)
      }
    }

    // Get new harbor project's id
    try {
      const res = await harborClient.get(`projects?name=${lagoonProjectName}`)
      var harborProjectID = res.body[0].project_id
      logger.debug(`Got the harbor project id for project ${lagoonProjectName} successfully!`)
    } catch (err) {
      if (err.statusCode == 404) {
        logger.error(`Unable to get the harbor project id of "${lagoonProjectName}", as it does not exist in harbor!`)
      } else {
        logger.error(`Unable to get the harbor project id of "${lagoonProjectName}", error: ${err}`)
      }
    }
    logger.debug(`Harbor project id for ${lagoonProjectName}: ${harborProjectID}`)

    // Create robot account for new harbor project
    try {
      const res = await harborClient.post(`projects/${harborProjectID}/robots`, {
        body: {
          name: lagoonProjectName,
          access: [
            {
              resource: `/project/${harborProjectID}/repository`,
              action: "push"
            }
          ]
        }
      })
      var harborTokenInfo = res.body
      logger.debug(`Robot was created for Harbor project ${lagoonProjectName} !`)
    } catch (err) {
      // 409 means project already exists
      // 201 means project created successfully
      if (err.statusCode == 409) {
        logger.warn(`Unable to create a robot account for harbor project "${lagoonProjectName}", as a robot account of the same name already exists!`)
      } else {
        logger.error(`Unable to create a robot account for harbor project "${lagoonProjectName}", error: ${err}`)
      }
    }

    // Set Harbor env vars for lagoon environment
    try {
      await query(
        sqlClient,
        Sql.insertEnvVariable({
          "name": "INTERNAL_REGISTRY_URL",
          "value": lagoonHarborRoute,
          "scope": "INTERNAL_CONTAINER_REGISTRY",
          "project": projectID,
        }),
      );
      logger.debug(`Environment variable INTERNAL_REGISTRY_URL for ${lagoonProjectName} created!`)

      await query(
        sqlClient,
        Sql.insertEnvVariable({
          "name": "INTERNAL_REGISTRY_USERNAME",
          "value": harborTokenInfo.name,
          "scope": "INTERNAL_CONTAINER_REGISTRY",
          "project": projectID,
        }),
      );
      logger.debug(`Environment variable INTERNAL_REGISTRY_USERNAME for ${lagoonProjectName} created!`)

      await query(
        sqlClient,
        Sql.insertEnvVariable({
          "name": "INTERNAL_REGISTRY_PASSWORD",
          "value": harborTokenInfo.token,
          "scope": "INTERNAL_CONTAINER_REGISTRY",
          "project": projectID,
        }),
      );
      logger.debug(`Environment variable INTERNAL_REGISTRY_PASSWORD for ${lagoonProjectName} created!`)
    } catch (err) {
      logger.error(`Error while setting up harbor environment variables for ${lagoonProjectName}, error: ${err}`)
    }

    // Set webhooks for Harbor Project
    try {
      var res = await harborClient.post(`projects/${harborProjectID}/webhook/policies`, {
        body: {
          targets: [
            {
              type: "http",
              skip_cert_verify: true,
              address: lagoonWebhookAddress
            }
          ],
          event_types: [
            "scanningFailed",
            "scanningCompleted"
          ],
          name: "Lagoon Default Webhook",
          enabled: true
        }
      });
    } catch (err) {
      logger.error(`Error while creating a webhook in the Harbor project for ${lagoonProjectName}, error: ${err}`)
    }
  },
  deleteProject: async (lagoonProjectName) => {
    // Delete harbor project

    // Get existing harbor project's id
    try {
      const res = await harborClient.get(`projects?name=${lagoonProjectName}`)
      var harborProjectID = res.body[0].project_id
      logger.debug(`Got the harbor project id for project ${lagoonProjectName} successfully!`)
    } catch (err) {
      if (err.statusCode == 404) {
        // This case could come to pass if a project was created
        // before we began using Harbor as our container registry
        logger.warn(`Unable to get the harbor project id of "${lagoonProjectName}", as it does not exist in harbor!`)
        return
      } else {
        logger.error(`Unable to get the harbor project id of "${lagoonProjectName}", error: ${err}`)
        return
      }
    }
    logger.debug(`Harbor project id for ${lagoonProjectName}: ${harborProjectID}`)

    // Check for existing repositories within the project
    try {
      const res = await harborClient.get(`search?name=${lagoonProjectName}`)
      const harborRepos = []
      for (i = 0; i < res.repository.length; i++) {
        if (res.repository[i].project_name == lagoonProjectName){
          harborRepos.push(res.repository[i])
        }
      }
    } catch (err) {
      logger.error(`Unable to search for repositories within the harbor project "${lagoonProjectName}", error: ${err}`)
    }

    // Delete any repositories within this project
    try {
      for (i = 0; i < harborRepos.length; i++) {
        var res = await harborClient.delete(`repositories/${harborRepos[i].repository_name}`)
      }
    } catch (err) {
      logger.error(`Unable to delete repositories within the harbor project "${lagoonProjectName}", error: ${err}`)
    }

    // Delete harbor project
    try {
      var res = await harborClient.delete(`projects/${harborProjectID}`);
      logger.debug(`Harbor project ${lagoonProjectName} deleted!`)
    } catch (err) {
      // 400 means the project id is invalid
      // 404 means project doesn't exist
      // 412 means project still contains repositories
      logger.error(`Unable to delete the harbor project "${lagoonProjectName}", error: ${err}`)
    }
  }
})

module.exports = createHarborOperations;