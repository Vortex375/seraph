# Seraph
Seraph is a WebDAV, CardDAV, CalDAV (and Subsonic) server with a distributed microservice architecture. It is written in Go (with a mobile app developed with Flutter/Dart, probably).

This project is in very early development. It is mostly a fun side-project for me to learn more about distributed architectures.

The goal for this project is to become a self-hosted alternative to commercial cloud providers. Unlike software like [Nextcloud](https://nextcloud.com/), Seraph does not aim to be a collaboration platform. Instead, it is targeted at single-user or home / family use-cases.

## Goals

- support WebDAV, CardDAV, CalDAV and Subsonic protocols
- support indexing and searching for files (with optional full-text search capability)
- support media file previews (thumbnails)
- support sharing (generate links providing access to files)
- mobile app supporting:
  - access to files and sharing
  - automatic upload of photos
  - gallery mode which allows seamless browsing of local photos and those stored online


Other things that would be cool:
- automatic image tagging and face recognition like [PhotoPrism](https://www.photoprism.app/)
- federated cloud features


# License
Seraph is licensed under the GNU Affero General Public License. See the [LICENSE](LICENSE) file for details.