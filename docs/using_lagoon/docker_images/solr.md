# Solr Image
Lagoon `Solr` image Dockerfile, based on the offical `solr:<version>-alpine` image.

This Dockerfile is intended to be used to setup a standalone Solr server with an initial core `mycore`.

## Lagoon & OpenShift adaptions
This image is prepared to be used on Lagoon which leverages OpenShift. There are therefore some things already done:

- Folder permissions are automatically adapted with [`fix-permissions`](https://github.com/sclorg/s2i-base-container/blob/master/core/root/usr/bin/fix-permissions) so this image will work with a random user and therefore also on OpenShift.
- `10-solr-port.sh` script to fix and check Solr port.
- `20-solr-datadir.sh` script to check if Solr config is compliant for Lagoon.

## Supported version
Lagoon support Solr versions: `5.5`, `6.6`, `7.5`

## Solr Drupal image
Lagoon `solr-drupal` Docker image, is a customized `solr` image to use within Drupal projects in Lagoon.
The initial core is `drupal` and it's created and configured starting from a Drupal customized and optimized configuration.
For each Solr version, there is a specific `solr-drupal:<version>` docker image.