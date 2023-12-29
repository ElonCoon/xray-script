#!/bin/bash

#更新系统
apt-get update -y

#安装依赖
apt install -y sudo nginx socat curl gnupg
systemctl enable nginx

#安装xray
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u root

# 删除config.json文件中的所有内容
> /usr/local/etc/xray/config.json

#配置config.json
uuid=$(xray uuid)
read -p "请输入Warp端口号：" warpport
cat << EOF >> /usr/local/etc/xray/config.json
{
    "log": {
        "loglevel": "warning"
    },
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
            {
                "type": "field",
                "ip": [
                    "geoip:cn",
                    "geoip:private"
                ],
                "outboundTag": "block"
            },
            {
	            "type": "field",
	            "domain": [
	            	"geosite:openai",
		            "geosite:disney",
		            "geosite:netflix"
	            ],
	            "outboundTag": "warp"
            }
        ]
    },
    "inbounds": [
        {
            "port": 443,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "$uuid", 
                        "flow": "xtls-rprx-vision",
                        "level": 0
                    }
                ],
                "decryption": "none",
                "fallbacks": [
                    {
                        "dest": "8001",
                        "xver": 1
                    },
                    {
                        "alpn": "h2",
                        "dest": "8002",
                        "xver": 1
                    }
                ]
            },
            "streamSettings": {
                "network": "tcp",
                "security": "tls",
                "tlsSettings": {
                    "rejectUnknownSni": true,
                    "minVersion": "1.2",
                    "alpn": [
                        "http/1.1",
                        "h2"
                    ],
                    "certificates": [
                        {
                            "ocspStapling": 3600,
                            "certificateFile": "/usr/local/etc/xray_cert/xray.crt",
                            "keyFile": "/usr/local/etc/xray_cert/xray.key"
                        }
                    ]
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": [
                    "http",
                    "tls"
                 ]
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "tag": "direct"
        },
        {
            "protocol": "blackhole",
            "tag": "block"
        },
        {
            "protocol": "socks",
            "settings": {
            "servers": [{
            "address": "127.0.0.1",
            "port": $warpport
            }]
        },
            "tag": "warp"
     
        }
    ]
}
EOF

# 安装WARP
curl https://pkg.cloudflareclient.com/pubkey.gpg | sudo gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/cloudflare-client.list
sudo apt-get update
sudo apt-get install cloudflare-warp -y
echo "请输入Warp登陆模式:"
read -p "1: Warp+ Key, 2: Zero Trust: " choice

case $choice in
    1)
        echo "您选择了 Warp+ Key"
        warp-cli register
        read -p "请输入Warp+ Key：" warpkey
        warp-cli set-license $warpkey
        warp-cli set-mode proxy
        warp-cli set-proxy-port $warpport
        warp-cli connect
        ;;
    2)
        echo "您选择了 Zero Trust"
	read -p "请输入您的团队名：" teamname
        warp-cli teams-enroll $teamname
	echo "***********************************************************************"
	echo "复制 “A browser window should open at the following URL:” 下面的链接在浏览器中打开"
	echo "在成功页面上，右键单击并选择“查看页面源”,复制URL字段：com.cloudflare.warp....."
        echo "***********************************************************************"
        read -p "请输入token：" token
        warp-cli teams-enroll-token $token
        warp-cli connect
	warp-cli account
        ;;
    *)
        echo "无效的选择"
        ;;
esac

# 安装Cloudreve
mkdir /usr/local/etc/cloudreve
wget https://github.com/cloudreve/Cloudreve/releases/download/3.8.3/cloudreve_3.8.3_linux_amd64.tar.gz
tar -zxvf cloudreve_3.8.3_linux_amd64.tar.gz -C /usr/local/etc/cloudreve/
chmod +x /usr/local/etc/cloudreve/cloudreve
flag=false
/usr/local/etc/cloudreve/cloudreve > /usr/local/etc/cloudreve/output.txt & cloudreve_pid=$!
sleep 5
if [ "$flag" = true ]; then
kill $cloudreve_pid
fi

# 获取Cloudreve初始管理员账号、密码和端口号
admin_user=$(grep -oP 'Admin user name: \K\S+' /usr/local/etc/cloudreve/output.txt)
admin_pass=$(grep -oP 'Admin password: \K\S+' /usr/local/etc/cloudreve/output.txt)
admin_port=$(grep -oP 'Listening to \K\S+' /usr/local/etc/cloudreve/output.txt)

# 输出默认账号、密码和端口号
echo "***********************************************************************"
echo "*                 初始管理员账号：$admin_user"
echo "*                 初始管理员密码：$admin_pass"
echo "*                 初始端口号：$admin_port"
echo "***********************************************************************"
echo "请记下账号、密码、端口号后按回车键继续..."
read -p ""

# 配置Cloudreve systemd服务
cat << EOF >> /usr/lib/systemd/system/cloudreve.service
[Unit]
Description=Cloudreve
Documentation=https://docs.cloudreve.org
After=network.target
After=mysqld.service
Wants=network.target

[Service]
WorkingDirectory=/usr/local/etc/cloudreve
ExecStart=/usr/local/etc/cloudreve/cloudreve
Restart=on-abnormal
RestartSec=5s
KillMode=mixed

StandardOutput=null
StandardError=syslog

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable cloudreve
systemctl start cloudreve
    
#删除output.txt
rm /usr/local/etc/cloudreve/output.txt
    
#删除cloudreve tar包
rm cloudreve_3.8.3_linux_amd64.tar.gz

# 安装BBR
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
sysctl -p

#安装acme
curl https://get.acme.sh | sh
.acme.sh/acme.sh --set-default-ca --server letsencrypt

#申请证书和安装证书
mkdir /usr/local/etc/xray_cert
read -p "输入您的域名：" domain
.acme.sh/acme.sh --issue -d $domain -k ec-256 --webroot /var/www/html
.acme.sh/acme.sh --install-cert -d $domain --ecc \
    --fullchain-file /usr/local/etc/xray_cert/xray.crt \
    --key-file /usr/local/etc/xray_cert/xray.key --reloadcmd "systemctl force-reload xray"
chmod +r /usr/local/etc/xray_cert/xray.key
.acme.sh/acme.sh --upgrade --auto-upgrade

#配置nginx.conf
# 删除nginx.conf文件中的所有内容
> /etc/nginx/nginx.conf
cat << EOF >> /etc/nginx/nginx.conf
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
	worker_connections 1024;
	# multi_accept on;
}
http {
    map \$http_upgrade \$connection_upgrade {
        default upgrade;
        ''      close;
    }
    server {
        listen 127.0.0.1:8001 proxy_protocol;
        listen 127.0.0.1:8002 http2 proxy_protocol;
        server_name  $domain;

        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers EECDH+CHACHA20:EECDH+CHACHA20-draft:EECDH+AES128:RSA+AES128:EECDH+AES256:RSA+AES256:EECDH+3DES:RSA+3DES:!MD5;
        ssl_prefer_server_ciphers on;
        ssl_session_cache shared:SSL:10m;
        ssl_session_timeout 10m;
        add_header Strict-Transport-Security "max-age=31536000";
        error_page 497  https://\$host\$request_uri;

        location / {
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header REMOTE-HOST \$remote_addr;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_pass http://127.0.0.1:5212;

            add_header X-Cache \$upstream_cache_status;

            set \$static_filerDMgmXdG 0;
            if ( \$uri ~* "\.(gif|png|jpg|css|js|woff|woff2)$" ) {
                set \$static_filerDMgmXdG 1;
                expires 1m;
            }
            if ( \$static_filerDMgmXdG = 0 ) {
                add_header Cache-Control no-cache;
            }
        }
    }
    server {
        listen  80;
        return 301 https://\$http_host\$request_uri;
    }
}
EOF

#重启服务
systemctl restart nginx
systemctl restart xray
systemctl restart cloudreve

encoded_uuid=$(echo -n "$uuid" | base64)
echo "*************************************************************************************"
echo "warp端口号：$warpport"
echo "*************************************************************************************"
echo "Shadowrocket链接：vless://$encoded_uuid?obfs=none&tls=1&peer=$domain&xtls=2"
echo "*************************************************************************************"
echo "Passwall链接：vless://$uuid@$domain:443?headerType=none&type=tcp&encryption=none&fp=randomized&flow=xtls-rprx-vision&security=tls&sni=$domain#备注"
echo "*************************************************************************************"
