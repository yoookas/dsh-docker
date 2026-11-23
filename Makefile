# 本地开发用的镜像名，可覆盖：make build IMAGE=dsh:dev
IMAGE ?= dsh:local
BASE_IMAGE ?= smanx/deepseek-harness:devtools-latest
PASSWORD ?= devpass
SSH_PORT ?= 2222

.PHONY: help prepare build run stop smoke lint fingerprint release-notes clean

help: ## 显示帮助
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

prepare: ## 读取上游 ENTRYPOINT/CMD，生成 docker/upstream-launch.sh
	bash scripts/gen-launcher.sh $(BASE_IMAGE) docker/upstream-launch.sh

build: prepare ## 构建镜像
	docker build -f docker/Dockerfile \
		--build-arg BASE_IMAGE=$(BASE_IMAGE) \
		--build-arg SOURCE_URL=local \
		-t $(IMAGE) .

run: ## 启动容器（SSH 2222 / Web 3080）
	docker run --rm -it --name dsh-dev \
		-p $(SSH_PORT):22 -p 3080:3080 \
		-e SSH_ROOT_PASSWORD=$(PASSWORD) \
		-v dsh-data:/root/.dsh \
		$(IMAGE)

stop: ## 停掉开发容器
	-docker rm -f dsh-dev

smoke: ## 冒烟测试（需要在本地有该镜像）
	bash scripts/smoke-test.sh $(IMAGE)

lint: ## shellcheck + dash/bash 语法检查
	shellcheck --shell=sh docker/entrypoint.sh docker/healthcheck.sh docker/install-openssh.sh docker/install-gh.sh docker/install-go.sh docker/upstream-launch.sh || true
	shellcheck scripts/*.sh || true
	dash -n docker/entrypoint.sh
	dash -n docker/healthcheck.sh
	dash -n docker/install-openssh.sh
	dash -n docker/install-gh.sh
	dash -n docker/install-go.sh
	for f in scripts/*.sh; do bash -n "$$f"; done
	docker run --rm -i hadolint/hadolint:2.12.0 hadolint --config .hadolint.yaml < docker/Dockerfile

fingerprint: ## 只算上游指纹，不构建
	bash scripts/upstream-fingerprint.sh | jq .

release-notes: ## 预览 Release 说明（需要先构建出 dist/*.tar.gz）
	bash scripts/make-release-notes.sh

clean: ## 清理临时产物
	rm -rf dist
