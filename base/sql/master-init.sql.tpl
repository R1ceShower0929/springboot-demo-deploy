-- MySQL 主库初始化脚本，容器第一次启动时自动执行
CREATE DATABASE IF NOT EXISTS demo DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
SET NAMES utf8mb4 COLLATE utf8mb4_general_ci;
USE demo;

CREATE TABLE IF NOT EXISTS t_user (
    id          BIGINT       NOT NULL AUTO_INCREMENT COMMENT '主键',
    username    VARCHAR(32)  NOT NULL COMMENT '用户名',
    email       VARCHAR(64)  DEFAULT NULL COMMENT '邮箱',
    age         INT          DEFAULT NULL COMMENT '年龄',
    create_time DATETIME     DEFAULT NULL COMMENT '创建时间',
    update_time DATETIME     DEFAULT NULL COMMENT '更新时间',
    deleted     TINYINT      NOT NULL DEFAULT 0 COMMENT '逻辑删除：0 正常 1 已删',
    PRIMARY KEY (id),
    KEY idx_username (username)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COMMENT = '用户表';

INSERT INTO t_user (username, email, age, create_time, update_time, deleted) VALUES
('张三', 'zhangsan@example.com', 28, NOW(), NOW(), 0),
('李四', 'lisi@example.com',     32, NOW(), NOW(), 0),
('王五', 'wangwu@example.com',   25, NOW(), NOW(), 0),
('赵六', 'zhaoliu@example.com',  41, NOW(), NOW(), 0),
('钱七', 'qianqi@example.com',   19, NOW(), NOW(), 0);

-- 主从复制账号（从库用它来拉 binlog）
CREATE USER IF NOT EXISTS 'repl'@'%' IDENTIFIED WITH mysql_native_password BY '__REPL_PASS__';
GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO 'repl'@'%';
FLUSH PRIVILEGES;
-- 应用专用账号：故意不给 SUPER/FILE 等全局权限，
-- 这样它在从库（read_only=ON）上执行写操作会被 ERROR 1290 拒绝
CREATE USER IF NOT EXISTS '__APP_USER__'@'%' IDENTIFIED WITH mysql_native_password BY '__APP_PASS__';
GRANT SELECT, INSERT, UPDATE, DELETE ON demo.* TO '__APP_USER__'@'%';
FLUSH PRIVILEGES;
