# 一起看房间服务

用于两个人同步观看 PiliPlus 中的普通视频和番剧。服务只传视频编号、播放状态、房间昵称和聊天文字；两台手机分别从哔哩哔哩加载视频，各自使用自己的登录和观看权限。无需给房间服务提供 B 站 Cookie。

## 用发布镜像部署

在 [Releases](https://github.com/MIKUSCAT/PiliPlus-Together/releases) 下载服务器对应架构的镜像和 `together-deploy.zip`，传到服务器。`uname -m` 为 `x86_64` 选 `amd64`，为 `aarch64` 选 `arm64`。镜像使用标准 `docker save` 格式，无需登录镜像仓库。

```sh
docker load -i piliplus-together-server-1.0.0-amd64.tar.gz
unzip together-deploy.zip -d together-deploy
cd together-deploy
cp .env.example .env
docker compose up -d
curl --fail http://127.0.0.1:3000/healthz
```

健康检查应返回 `{"status":"ok","protocol":1}`。默认仅绑定本机 `127.0.0.1:3000`，适合接到现有 Nginx、Caddy 或宝塔 HTTPS 反代。参考同目录 `nginx.conf.example`，需要启用 WebSocket 转发。手机填写反代后的 `https://你的域名`。

### 没有现成的 HTTPS 反代

把域名解析到服务器，在 `.env` 设置 `TOGETHER_DOMAIN=你的域名`，开放 TCP 80、443，然后执行：

```sh
docker compose -f compose.yaml -f compose.https.yaml up -d
curl --fail https://你的域名/healthz
```

Caddy 会自动申请和续期证书。国内服务器使用域名和 80/443 端口时，按云厂商要求完成备案。已有服务占用这两个端口时，使用现有反代配置即可。Caddy 镜像需要从 Docker Hub 拉取，若网络受限，可使用朋友服务器已有的反代。

### 临时用 IP 联调

将 `.env` 的 `BIND_ADDRESS` 改成 `0.0.0.0`，开放所用 TCP 端口，再 `docker compose up -d`。两台手机填写 `http://服务器IP:3000`。正式使用建议配置 HTTPS，避免房间邀请码和会话在传输中被读取。

## 更新与运行

```sh
docker compose logs --tail 100 together
docker compose ps
# 加载新版镜像后重新创建容器：
docker compose up -d --force-recreate together
```

房间和最近 50 条聊天消息只保存在内存中，不写数据库。服务重启后重新建房即可。断线时保留成员席位，原设备会自动恢复；双方明确退出后，房间立即删除；双方离线超过 30 分钟后清理。房间码只能容纳两人，请只分享给要一起看的人。服务不记录视频链接、B 站账号或会话密钥到日志。

`MAX_ROOMS` 默认为 100。朋友自用可以设为 10；每个房间最多两人。容器内部端口保持 3000，对外端口使用 `.env` 中的 `PORT`。

## 从源码构建

```sh
cd server
npm ci
npm test
npm start
# 或者：
docker build -t piliplus-together-server:1.0.0 .
```

需要 Node.js 22 或更新版本（发布镜像使用 Node.js 24）。测试包含真实的双 WebSocket 客户端，以及暂停/缓冲冲突、旧视频指令、第三人拒绝、重连会话和时长不一致。

GitHub Actions 的 **Together server images** 工作流可重新生成 amd64 和 arm64 镜像；下载对应 artifacts，解压后用 `docker load` 导入。

## 协议与同步方式

- HTTP `GET /healthz`；WebSocket `/ws`；协议版本为 1。
- 服务端统一记录视频、播放意图、时间轴、倍速、媒体代次和状态版本。操作按服务端接收顺序生效，最后一个明确操作为准。
- 单人可以先看；有人加入后，等房间内所有成员在线、视频就绪、没有缓冲或暂离时继续同步播放。对方主动退出后可以继续单人播放，临时断线仍会等待重连。缓冲导致的等待不会覆盖任一人的手动暂停。
- 客户端用往返时间估计服务端时钟，偏差较大时纠正进度，避免正常解码抖动导致反复跳播。
- 自动跳过和播放完自动换集只由一端发起，另一端跟随；主控离线后可转移。手动控制对双方始终开放。
- 每位成员持有独立的恢复凭据；服务器只保存凭据的摘要，房间广播不包含凭据。
