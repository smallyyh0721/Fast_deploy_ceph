# 集群元数据备份 `backup-cluster-meta.sh`

**默认不运行**：不在 `deploy.sh` 流程里，脚本不装 cron / systemd timer。需要时在带 `_admin` 标签的节点（node1）手动执行：

```bash
cd /opt/ceph-offline/offline
sudo ./backup-cluster-meta.sh --dry-run            # 只列出要导出的内容
sudo ./backup-cluster-meta.sh                      # -> /var/backups/ceph-meta/ceph-meta-<fsid>-<YYYYmmdd-HHMMSS>.tar.gz
sudo ./backup-cluster-meta.sh --out /data/bk       # 或 cluster.conf / 环境变量 BACKUP_DIR=/data/bk
```

只读：所有命令都是查询（`cephadm shell -- ... </dev/null`），不改集群。内容：
- `/etc/ceph`（ceph.conf、admin keyring、ceph.pub）
- `ceph auth ls`、`config dump`、`config-key dump`、`orch ls --export`、`orch host ls`
- crushmap（`osd getcrushmap` 二进制 + `osd crush dump` JSON）、`mon dump`、`osd dump`、`osd tree`、`fs dump`、`versions`、`mgr services`、`ceph -s`
- RGW：`radosgw-admin realm list` / `zonegroup get` / `zone get` / `period get`（没部署 RGW 时记为 skip）
- `MANIFEST.txt`、`SHA256SUMS`

输出目录 700，tar 文件 600。**tar 里有所有 CephX 密钥和 dashboard 等 config-key 秘密**：拷走后加密保存，不要放在集群节点或共享盘上。任何一项失败：tar 仍生成（含 `.err`），脚本退出码非 0。

恢复用途：对照 `orch ls --export`（服务规格，可 `ceph orch apply -i`）、`config dump`、`auth ls`、crushmap（`crushtool -d crushmap.bin`）重建/核对配置。这不是数据备份。

## 可选：自行定时（示例，脚本不会安装）
cron（每天 02:30，保留 30 天）：
```cron
30 2 * * * root /opt/ceph-offline/offline/backup-cluster-meta.sh --out /var/backups/ceph-meta >>/var/log/ceph-meta-backup.log 2>&1 && find /var/backups/ceph-meta -name 'ceph-meta-*.tar.gz' -mtime +30 -delete
```
或 systemd timer：
```ini
# /etc/systemd/system/ceph-meta-backup.service
[Service]
Type=oneshot
ExecStart=/opt/ceph-offline/offline/backup-cluster-meta.sh --out /var/backups/ceph-meta
# /etc/systemd/system/ceph-meta-backup.timer
[Timer]
OnCalendar=*-*-* 02:30
Persistent=true
[Install]
WantedBy=timers.target
```
`systemctl enable --now ceph-meta-backup.timer`。
