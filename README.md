# 云吞插件：qBittorrent

开发流程见[插件开发指南](https://github.com/geraldpeng6/wonton-docs/blob/main/develop.md)。

云吞（Wonton）的 qBittorrent 插件：在共享文件夹 `downloads` 中下载和管理 BT 任务。网页经云吞网关访问，BT 连接端口按需开放到局域网。

这个插件使用上游官方镜像 `qbittorrentofficial/qbittorrent-nox`，网页界面是 [VueTorrent](https://github.com/VueTorrent/VueTorrent)；网关来源地址写入 qBittorrent 的免认证白名单，因此打开网页不用再输一次密码。

## VueTorrent 界面

VueTorrent 由 init 服务在安装和每次启动时从 [VueTorrent 官方发版](https://github.com/VueTorrent/VueTorrent/releases) 取来，解压进插件数据目录，交给 qBittorrent 当备用 WebUI；版本号和 zip 的 sha256 写死在 `docker-compose.yml` 的 `VUETORRENT_VERSION`、`VUETORRENT_SHA256` 里。升级 VueTorrent：把这两行改成新版本和它的 sha256（下载地址形如 `https://github.com/VueTorrent/VueTorrent/releases/download/<版本>/vuetorrent.zip`）。Dependabot 认不出这两个变量，不会自动开升级 PR。

不想用 VueTorrent 时，两种切回原版界面的办法：

- VueTorrent 里打开 设置 → qBittorrent → WebUI，取消勾选“使用备用 WebUI”；
- VueTorrent 打不开时，把插件数据目录里 `config/qBittorrent/config/qBittorrent.conf` 的 `WebUI\AlternativeUIEnabled` 改成 `false`，然后重启插件。

设置过的选择会保留：init 服务只在配置里没有这两项时（老版本升级上来）补上默认值，不覆盖用户改过的值。

## 图标来源与许可

`icon.svg` 使用 qBittorrent 官方标志；来源、处理方式、许可证全文和商标说明见 [NOTICE](NOTICE)。

## 先跑起来

```bash
scripts/dev.sh up
scripts/dev.sh install
```

`up` 在本机起一套云吞，打印它的地址。浏览器打开，用 `scripts/dev.sh token` 输出的用户令牌登录。`install` 先列出插件要的权限，确认后装上，打印 qBittorrent 网页的地址。打开就是 VueTorrent，不需要再输入 qBittorrent 密码。

下载默认写入共享文件夹 `downloads`；BT 端口 51413 的 TCP 和 UDP 可按安装时授权开放到局域网。应用网页只经云吞网关访问。

Chrome、Firefox 和 curl 把 `*.localhost` 直接解析到本机，不用改 hosts。

## 仓库里有什么

| 路径 | 内容 |
| --- | --- |
| `docker-compose.yml` | 插件本身：Compose 加上 `x-wonton` 清单 |
| `icon.svg`、`config/` | 清单和 Compose 引用的文件：官方图标、qBittorrent 配置种子和初始化脚本 |
| `screenshots/` | 商店详情页里的截图 |
| `scripts/check.sh` | 检查插件包，规则和安装时一样 |
| `scripts/dev.sh` | 开发环境：起一套云吞，装、重装、卸载插件，看日志 |
| `scripts/smoke-probes.sh` | `scripts/dev.sh smoke` 对这个插件逐项的探测 |
| `scripts/publish.sh` | 发布一个版本：打 tag、推送 |
| `AGENTS.md` | 给人和 AI 编程代理的规则 |
| `LICENSE`、`NOTICE` | 插件包许可证、上游许可证和商标声明 |
| `.wonton/` | 开发环境的设置、密钥和数据，不提交 |
