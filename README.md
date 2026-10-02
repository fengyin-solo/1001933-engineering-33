# 风电场机组运维平台

面向风电场站台账、机组部件监测、变桨偏航调试、缺陷处置与上网电量结算的一体化运维后台。

这是一个前后端分离的管理平台：前端 Vue 3 + Vite + TypeScript，后端 FastAPI（Python）。
两边各自独立启动，前端 dev server 已关掉自动打开页面，启动后按终端打印的地址手工打开。

## 目录结构

```text
.
├── frontend/                 Vue 3 + Vite + TypeScript 前端
│   ├── src/views/            每个业务模块一个页面
│   ├── src/api/              统一请求封装
│   ├── src/stores/           会话与筛选状态
│   └── vite.config.ts        dev server 配置（open: false）
├── backend/                  FastAPI（Python） 后端
│   ├── app/routers/          每个业务模块一组接口
│   ├── app/services/         业务规则与状态流转
│   └── app/store.py          内存数据仓库与示例数据
├── .gitignore
└── docker-compose.yml
```

## 启动

### 后端

```bash
cd backend
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
./run.sh
```

健康检查：`curl http://127.0.0.1:8000/api/health`

### 前端

```bash
cd frontend
npm install
npm run dev
```

前端默认监听 `http://127.0.0.1:5173/`，dev server 不会自动打开浏览器，
需要自己访问。`/api` 由 vite 代理到后端 `http://127.0.0.1:8000`。

### 一键启动备件领用链路（`scripts/dev-up.sh`）

换机器或交接时不想逐段敲命令，可以直接跑：

```bash
./scripts/dev-up.sh
```

它会在**同一次执行**里依次完成，任一步失败立即停下、打印缺什么并自动重试一次：

1. 按锁文件装齐两端依赖：后端 `backend/requirements.lock`（独立虚拟环境）、
   前端 `frontend/package-lock.json`（`npm ci`）。
   系统 Python 缺 `venv/pip` 时会自动下载一份临时 uv 引导，不写系统目录。
2. 启动后端，备件领用示例数据随服务启动自动灌入（早先导入的 3 条领用单
   已回填为历史记录，缺失字段一并补齐）。
3. 启动前端，并把 vite 的 `/api` 代理显式指向本次后端端口，两端地址不会再对不上。
4. 自动验收（`scripts/verify_spare.py`，请求都经前端代理，即浏览器真实链路）：
   - 领用单列表页 `GET /api/spare`；
   - 登记接口 `POST /api/spare`，验备件名称、备件规格两个字段，并验缺字段时的报错；
   - 汇总卡片 `GET /api/spare/stats` 与列表条数一致。

隔离与可重入：

- 每次执行使用独立临时目录与动态空闲端口，不占用 8000/5173，不干扰本机其它任务；
  临时 venv、npm/pip 缓存都在临时目录里，Ctrl-C 或跑完自动清理。
- 重跑会先清掉上一次（含失败/中断残留）的临时目录；失败现场默认保留并打印路径。
- 同一仓库同时只允许一个实例（避免并发 `npm ci` 互踩 `node_modules`）。
- 本脚本不改写上面的手动命令；日常本地开发仍按 `Makefile` / `run.sh` /
  `npm run dev` 那套走即可。


## 业务模块

| 模块 | 目录 | 业务对象 | 主要字段 |
| --- | --- | --- | --- |
| 风电场站 | `windfarm` | 风电场站 | 场站编码、场站名称、所在区域 |
| 风电机组 | `turbine` | 风电机组 | 机组编号、机组机型、额定功率 |
| 叶片 | `blade` | 叶片 | 叶片编号、所属机组、叶片长度 |
| 齿轮箱 | `gearbox` | 齿轮箱 | 齿轮箱编号、所属机组、油温上限 |
| 发电机 | `generator` | 发电机 | 发电机编号、所属机组、额定电压 |
| 变桨系统 | `pitch` | 变桨系统 | 系统编号、所属机组、变桨方式 |
| 偏航系统 | `yaw` | 偏航系统 | 系统编号、所属机组、偏航方式 |
| 测风塔 | `metmast` | 测风塔 | 塔架编号、所在场站、塔架高度 |
| 集电线路 | `collector` | 集电线路 | 线路编号、电压等级、起止杆塔 |
| 升压站 | `substation` | 升压站 | 站区编号、主变容量、电压等级 |
| 功率预测 | `forecast` | 功率预测单 | 预测单号、所属场站、预测日期 |
| 振动监测 | `vibration` | 振动监测记录 | 监测编号、监测部位、所属机组 |
| 缺陷登记 | `defect` | 机组缺陷 | 缺陷编号、缺陷部位、缺陷等级 |
| 检修任务 | `maintjob` | 检修任务单 | 任务编号、关联机组、检修类型 |
| 备件领用 | `spare` | 备件领用单 | 领用单号、备件名称、备件规格 |
| 巡视检查 | `patrol` | 巡视单 | 巡视单号、巡视路线、巡视人员 |
| 验收确认 | `accept` | 验收单 | 验收单号、关联任务、验收项目 |
| 电量结算 | `settle` | 电量结算单 | 结算单号、结算周期、所属场站 |

## 约定

- 每个模块的前端页面在 `frontend/src/views/<模块>/index.vue`，后端接口在
  `backend/app/routers/<模块>.py`，业务规则在 `backend/app/services/<模块>.py`。
- 列表接口统一返回 `{ items, total, page, size }`，动作接口统一返回 `{ ok, message }`。
- 状态流转只允许在 `app/services` 里改，路由层不做业务判断。
