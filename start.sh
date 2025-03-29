#!/bin/bash

# 设置错误时退出
set -e

# 激活虚拟环境
source venv/bin/activate

echo "开始启动 MaxKB 服务..."

# 检查 Docker 是否运行
if ! docker info > /dev/null 2>&1; then
    echo "错误: Docker 未运行，请先启动 Docker"
    exit 1
fi

# 创建数据目录
echo "创建数据目录..."
mkdir -p /mnt/postgres/data

# 检查磁盘空间
echo "检查磁盘空间..."
if [ $(df -h / | awk 'NR==2 {print $5}' | sed 's/%//') -gt 90 ]; then
    echo "警告: 磁盘空间不足，正在清理..."
    # 清理未使用的 Docker 资源
    docker system prune -f
    # 清理日志文件
    find /var/log -type f -name "*.log" -exec truncate -s 0 {} \;
    # 清理临时文件
    rm -rf /tmp/*
fi

# 检查 PostgreSQL 容器是否运行
if ! docker ps | grep -q "postgres.*5432"; then
    if docker ps -a | grep -q "postgres"; then
        echo "PostgreSQL 容器已存在但未运行，正在启动..."
        docker start postgres
    else
        echo "启动 PostgreSQL 容器..."
        docker run -d \
            --name postgres \
            -e POSTGRES_PASSWORD=postgres \
            -e POSTGRES_DB=maxkb \
            -p 5432:5432 \
            -v /mnt/postgres/data:/var/lib/postgresql/data \
            ankane/pgvector:v0.5.1
        echo "PostgreSQL 容器已启动"
    fi
else
    echo "PostgreSQL 容器已在运行"
fi

# 等待 PostgreSQL 就绪
echo "等待 PostgreSQL 就绪..."
until docker exec postgres pg_isready -U postgres > /dev/null 2>&1; do
    echo "等待 PostgreSQL 启动..."
    sleep 2
done
echo "PostgreSQL 已就绪"

# 创建 vector 扩展
echo "创建 vector 扩展..."
docker exec postgres psql -U postgres -d maxkb -c "CREATE EXTENSION IF NOT EXISTS vector;"

# 检查是否需要重新构建前端
if [ -d "ui/node_modules" ]; then
    echo "检查前端依赖是否需要更新..."
    cd ui
    if [ -f "package-lock.json" ]; then
        if [ "package-lock.json" -ot "package.json" ]; then
            echo "更新前端依赖..."
            npm install
        fi
    else
        echo "安装前端依赖..."
        npm install
    fi
    
    echo "构建前端..."
    npm run build
    cd ..
else
    echo "首次安装前端依赖..."
    cd ui
    npm install
    echo "构建前端..."
    npm run build
    cd ..
fi

# 检查是否需要数据库迁移
echo "检查数据库迁移..."
source venv/bin/activate
cd apps
python manage.py makemigrations
python manage.py migrate
cd ..

# 清除缓存
echo "清除缓存..."
rm -rf data/cache/*

# 检查是否已有服务在运行
if pgrep -f "python main.py start" > /dev/null; then
    echo "停止已运行的服务..."
    pkill -f "python main.py start"
    sleep 2
fi

# 启动服务
echo "启动 MaxKB 服务..."
nohup python main.py start > logs/maxkb.log 2>&1 &

# 等待服务启动
echo "等待服务启动..."
sleep 5

# 检查服务是否成功启动
if pgrep -f "python main.py start" > /dev/null; then
    echo "MaxKB 服务已成功启动"
    echo "日志文件: logs/maxkb.log"
    echo "使用 'tail -f logs/maxkb.log' 查看日志"
else
    echo "服务启动失败，请检查日志文件"
    exit 1
fi
