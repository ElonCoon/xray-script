#!/bin/bash
      
# 安装基础软件
installBasicsoftware() {
    apt update -y
    apt install -y sudo nginx socat curl gnupg
    systemctl enable nginx
    curl https://get.acme.sh | sh
    .acme.sh/acme.sh --set-default-ca --server letsencrypt
}

# 申请SSL证书
Applyforsslcertificate() {
    mkdir /usr/local/etc/xray_cert
    read -p "输入您的域名：" domain
    .acme.sh/acme.sh --issue -d $domain -k ec-256 --webroot /var/www/html
    .acme.sh/acme.sh --install-cert -d $domain --ecc \
      --fullchain-file /usr/local/etc/xray_cert/xray.crt \
      --key-file /usr/local/etc/xray_cert/xray.key --reloadcmd "systemctl force-reload nginx"
    chmod +r /usr/local/etc/xray_cert/xray.key
    .acme.sh/acme.sh --upgrade --auto-upgrade

    # 创建证书续订脚本
    cat <<EOF > /usr/local/etc/xray_cert/xray-cert-renew.sh
 #!/bin/bash

.acme.sh/acme.sh --install-cert -d $domain --ecc --fullchain-file /usr/local/etc/xray_cert/xray.crt --key-file /usr/local/etc/xray_cert/xray.key
echo "Xray证书已更新"

chmod +r /usr/local/etc/xray_cert/xray.key
echo "私钥读取权限已授予"

systemctl restart xray
echo "Xray已重启"
EOF

    chmod +x /usr/local/etc/xray_cert/xray-cert-renew.sh
    (crontab -l ; echo "0 1 1 * * bash /usr/local/etc/xray_cert/xray-cert-renew.sh") | crontab -

    # 配置Nginx
    rm /etc/nginx/nginx.conf
    cat > /etc/nginx/nginx.conf <<'EOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
	worker_connections 1024;
	# multi_accept on;
}
http {
server {
    listen 127.0.0.1:8001 proxy_protocol;
    listen 127.0.0.1:8002 http2 proxy_protocol;
    server_name  $domain;
    real_ip_header proxy_protocol;
    location / {
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header Host $http_host;
      proxy_redirect off;
      proxy_pass http://127.0.0.1:5212;
    }
}
server {
    listen  80;
    server_name  $domain;
    return 301 https://$server_name$request_uri;
}
}
EOF
}

# 安装Xray
installxray() {
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u root

    uuid=$(xray uuid)
    cat > /usr/local/etc/xray/config.json <<EOF
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
            "port": 26262
            }]
        },
            "tag": "warp"
     
        }
    ]
}
EOF
}

# 安装WARP
installwarp() {
    curl https://pkg.cloudflareclient.com/pubkey.gpg | sudo gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/cloudflare-client.list
    sudo apt-get update
    sudo apt-get install cloudflare-warp -y
    warp-cli register
    read -p "请输入WarpKey：" warpkey
    warp-cli set-license $warpkey
    warp-cli set-mode proxy
    warp-cli set-proxy-port 26262
    warp-cli connect
}

# 安装Cloudreve
installcloudre() {
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
    echo "*                 初始管理员账号：$admin_user                            *"
    echo "*                 初始管理员密码：$admin_pass                            *"
    echo "*                 初始端口号：$admin_port                               *"
    echo "***********************************************************************"
    echo "请记下账号、密码、端口号后按回车键继续..."
    read -p ""

    # 配置Cloudreve systemd服务
    cat <<EOF > /usr/lib/systemd/system/cloudreve.service
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
}

# 安装BBR
installbbr() {
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p
}

#重启服务
Restartservice() {
    systemctl restart nginx
    systemctl restart xray
    systemctl restart cloudreve
}
task_status=("未完成" "未完成" "未完成" "未完成" "未完成" "未完成")
while true; do
    echo "*****************************按顺序执行********************************"
    echo "*                         1.安装基础软件${task_status[1]}      "
    task_status[1]="(已完成)"
    echo "*                         2.申请SSL证书${task_status[2]}       "
    task_status[2]="(已完成)"
    echo "*                         3.安装Xray${task_status[3]}         "
    task_status[3]="(已完成)"
    echo "*                         4.安装WARP${task_status[4]}         "
    task_status[4]="(已完成)"
    echo "*                         5.安装Cloudreve${task_status[5]}   "
    task_status[5]="(已完成)"
    echo "*                         6.安装BBR${task_status[6]}        "
    task_status[6]="(已完成)"
    echo "*                         7.重启服务                        "
    echo "*                         8.退出                           "
    echo "*********************************************************************"
    read -p "请选择:" option
    case ${option} in
    1)
       installBasicsoftware
       continue
       ;;
    2)
       Applyforsslcertificate
       continue
       ;;
    3)
       installxray
       continue
       ;;
    4)
       installwarp
       continue
       ;;
    5)
       installcloudre
       continue
       ;;
    6)
       installbbr
       continue
       ;;
    7)
       Restartservice
       continue
       ;;
    8)
       exit 0
       ;;
     *)
        echo "无效的选择，请重新输入！"
        ;;
    esac
done
