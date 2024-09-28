# Seraph
Seraph is a WebDAV, CardDAV, CalDAV (and Subsonic) server with a distributed microservice architecture. It is written in Go (with a mobile app developed with Flutter/Dart, probably).

This project is in very early development. It is mostly a fun side-project for me to learn more about distributed architectures.

The goal for this project is to become a self-hosted alternative to commercial cloud providers. Unlike software like [Nextcloud](https://nextcloud.com/), Seraph does not aim to be a collaboration platform. Instead, it is targeted at single-user or home / family use-cases.

# Goals

- support WebDAV, CardDAV, CalDAV and Subsonic protocols
- support access management using "spaces" - spaces group together resources (files, calendars etc.) and assign them to users and roles
- support indexing and searching for files (with optional full-text search capability)
- support media file previews (thumbnails)
- support sharing (generate links providing access to files)
- mobile app supporting:
  - access to files and sharing
  - automatic upload of photos
  - gallery mode which allows seamless browsing of local photos and those stored online
- support distributed microservice and "monolith" mode (all microservices running in one process)

Other things that would be cool:
- automatic image tagging and face recognition like [PhotoPrism](https://www.photoprism.app/)
- federated cloud features
- media stream transcoding
- file versioning / backup features

Things that probably won't be implemented:
- file synchronization (with the exception of photo upload) - there are great alternatives like [Syncthing](https://syncthing.net/) available
- collaborative editing / online editing of documents in general

# License
Seraph is licensed under the GNU Affero General Public License. See the [LICENSE](LICENSE) file for details.
