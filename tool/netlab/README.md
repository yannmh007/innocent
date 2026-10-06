# netlab — the Local Network core against real servers

`android/app/src/main/kotlin/com/innocent/media/net/core` is plain JVM code
(no `android.*`), so this Gradle project compiles those very files on a
desktop JVM and tests them against the servers people actually run:

| Server | Port | What it stands in for |
|---|---|---|
| Samba 4, SMB2/3 | 445 | Windows shares, NAS boxes |
| Samba 4, NT1 only | 4451 | an old router's USB share (SMB1 → jcifs-ng) |
| vsftpd | 2121 | FTP (anonymous and account, passive and active, GBK names) |
| vsftpd + TLS | 2122 | FTPS explicit, `require_ssl_reuse=YES` |
| vsftpd + TLS | 9900 | FTPS implicit |
| OpenSSH | 2222 | SFTP: password, ed25519 key, passphrase-protected RSA PEM |

```sh
sudo apt-get install samba vsftpd openssh-server smbclient ffmpeg
sudo tool/netlab/servers.sh start      # state in /tmp/netlab
cd tool/netlab && gradle test
```

The device lab (`NETLAB=1` in `test_device/config.env`) starts the same
servers on the runner, runs these tests, and then drives the app on the
emulator against them (`test_device/flows/network.yaml`, host `10.0.2.2`).
