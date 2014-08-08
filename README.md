# ***trackergate*** - BitTorrent tracker proxy that helps clients announce to UDP trackers via HTTPS

## Introduction

As [more](http://openbittorrent.com/) [and](http://publicbt.com/) [more](http://istole.it/) BitTorrent trackers [offer](http://demonii.com/) [support](http://coppersurfer.tk/) for the [UDP tacker protocol](http://www.bittorrent.org/beps/bep_0015.html), some ISPs are blocking it in their evil attempt to curb BitTorrent traffic. ***trackergate*** helps overcome that barrier by providing a HTTPS-to-UDP-and-back-to-HTTPS proxy for the `announce` message.

## Usage

### System requirement

You need to run trackergate on a computer where you has the priveledges to:
- listen for incoming HTTPS connections on a TCP port
- send and receive packages to and from UDP trackers without ISP interference
- run [node.js](http://nodejs.org/) scripts

### Installation

(Until proper installation is implemented...)

Install trackergate by downloading all files from this repository, then:

`npm install .`

### Configuration

(Until proper configuration is implemented...)

Configure trackergate by editing `config.json`

You can generate SSL key and certificate properly using [openssl](http://www.sslshopper.com/article-most-common-openssl-commands.html) or quick-and-dirty [online](http://www.selfsignedcertificate.com/)

### Announce

In your BitTorrent client, find the UDP tracker you cannot announce to directly, then replace `udp://[tracker.hostname]:[port]` with `https://[trackergate.hostname]:[port]/[passkey]/[tracker.hostname]/[port]/announce`

## Author

[Henry 'Pi' James](https://github.com/henrypijames), former development team member of Bram Cohen's original BitTorrent software

## License

[GNU General Public License 3.0](https://www.gnu.org/licenses/gpl-3.0.txt)
