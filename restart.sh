#!/usr/bin/expect -f

# Genel değişkenler
set timeout -1
set cpu_threshold 50
set log_file "/tmp/gensyn_auto.log"

# Log dosyasını oluştur veya temizle
exec echo "=== Gensyn Auto Script Started: [clock format [clock seconds]] ===" > $log_file

# Timestamp fonksiyonu
proc timestamp {} {
    return [clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S"]
}

# Log fonksiyonu - hem ekrana hem dosyaya yazar
proc log_msg {msg} {
    global log_file
    set timestamp [timestamp]
    puts "\[$timestamp\] $msg"
    exec sh -c "echo '\[$timestamp\] $msg' >> $log_file"
}

# Tüm yanıtları ver - ayrı fonksiyon olarak
proc handle_prompts {} {
    # Bu fonksiyon tek başına tüm sorulara yanıt verir
    expect {
        "Enter your choice (1 or 2):" {
            send "1\r"
            log_msg "swarm.pem sorusuna yanıt verildi: 1"
            exp_continue
        }
        "Please select a swarm to join:" {
            # Biraz bekleyerek ">" prompt'unun gelmesini sağla
            sleep 1
            send "A\r"
            log_msg "Swarm seçim sorusuna yanıt verildi: A"
            exp_continue
        }
        ">" {
            # Hangi soru olduğunu anlamak için önceki çıktıya bak
            if {[string match "*swarm to join*" $expect_out(buffer)]} {
                send "A\r"
                log_msg "Swarm seçim sorusuna yanıt verildi: A"
            } elseif {[string match "*parameters*" $expect_out(buffer)]} {
                send "0.5\r"
                log_msg "Parametre sorusuna yanıt verildi: 0.5"
            }
            exp_continue
        }
        "How many parameters" {
            # Biraz bekleyerek ">" prompt'unun gelmesini sağla
            sleep 1
            send "0.5\r"
            log_msg "Parametre sorusuna yanıt verildi: 0.5"
            exp_continue
        }
        "Would you like to push models you train in the RL swarm to the Hugging Face Hub?" {
            send "N\r"
            log_msg "Hugging Face sorusuna yanıt verildi: N"
            exp_continue
        }
        "\\\[y/N\\\]" {
            send "N\r"
            log_msg "Hugging Face sorusuna yanıt verildi: N"
            exp_continue
        }
        "Connected to Gensyn Testnet" {
            log_msg "✅ Gensyn Testnet'e başarıyla bağlanıldı!"
            exp_continue
        }
        -re {failed to connect to bootstrap peers|Daemon failed to start|P2PDaemonError} {
            log_msg "❌ Bağlantı hatası tespit edildi! Yeniden başlatılıyor..."
            restart_app
            exp_continue
        }
        eof {
            log_msg "Program sonlandı. Yeniden başlatılıyor..."
            restart_app
            exp_continue
        }
        timeout {
            log_msg "Beklenmeyen bir timeout oluştu. İzleme devam ediyor..."
            exp_continue
        }
    }
}

# Uygulamayı yeniden başlat fonksiyonu
proc restart_app {} {
    global spawn_id
    log_msg "Gensyn durduruluyor ve yeniden başlatılıyor..."
    
    # Ctrl+C sinyali gönder (2-3 kez)
    for {set i 0} {$i < 3} {incr i} {
        send "\003"
        sleep 2
    }
    
    # Mevcut işlemi sonlandır
    catch {close}
    catch {wait}
    
    # Yeni işlemi başlat
    log_msg "Yeni Gensyn işlemi başlatılıyor..."
    spawn bash -c "cd \$HOME && rm -rf gensyn-testnet && git clone https://github.com/zunxbt/gensyn-testnet.git && chmod +x gensyn-testnet/gensyn.sh && ./gensyn-testnet/gensyn.sh"
    
    # Tüm yanıtları tekrar ver
    handle_prompts
}

# CPU izleme - ayrı bir process olarak çalışacak
proc start_cpu_monitor {} {
    global cpu_threshold log_file
    
    # CPU izleme komutunu bash script olarak oluştur
    set cpu_script "/tmp/gensyn_cpu_monitor.sh"
    set fh [open $cpu_script "w"]
    
    puts $fh "#!/bin/bash"
    puts $fh "echo 'CPU izleme başlatıldı: \$(date)' >> $log_file"
    puts $fh "low_cpu_count=0"
    puts $fh "max_low_cpu=60  # 1 saat (her dakika kontrol)"
    puts $fh "while true; do"
    puts $fh "  gensyn_pid=\$(pgrep -f 'gensyn-testnet/gensyn.sh')"
    puts $fh "  if \[ -z \"\$gensyn_pid\" \]; then"
    puts $fh "    echo '\$(date): CPU izleme - Gensyn işlemi bulunamadı' >> $log_file"
    puts $fh "    sleep 30"
    puts $fh "    continue"
    puts $fh "  fi"
    puts $fh "  cpu_usage=\$(ps -p \$gensyn_pid -o %cpu= | awk '{print int(\$1)}')"
    puts $fh "  echo '\$(date): CPU kullanımı: \${cpu_usage}%' >> $log_file"
    puts $fh "  if \[ \"\$cpu_usage\" -lt \"$cpu_threshold\" \]; then"
    puts $fh "    low_cpu_count=\$((low_cpu_count + 1))"
    puts $fh "    echo '\$(date): Düşük CPU sayacı: \$low_cpu_count/\$max_low_cpu' >> $log_file"
    puts $fh "    if \[ \"\$low_cpu_count\" -ge \"\$max_low_cpu\" \]; then"
    puts $fh "      echo '\$(date): CPU uzun süre düşük! Uygulamayı durdurun (2-3 kez Ctrl+C) ve tekrar başlatın' >> $log_file"
    puts $fh "      # Burada doğrudan kill etmiyoruz, expect script'e bilgi veriyoruz"
    puts $fh "      touch /tmp/gensyn_restart_needed"
    puts $fh "      low_cpu_count=0"
    puts $fh "    fi"
    puts $fh "  else"
    puts $fh "    low_cpu_count=0"
    puts $fh "  fi"
    puts $fh "  sleep 60"
    puts $fh "done"
    
    close $fh
    exec chmod +x $cpu_script
    
    # CPU izleme scriptini başlat
    log_msg "CPU izleme başlatılıyor (eşik: %$cpu_threshold, süre: 1 saat)"
    exec $cpu_script &
}

# CPU izlemesini kontrol eden fonksiyon
proc check_cpu_restart {} {
    if {[file exists "/tmp/gensyn_restart_needed"]} {
        log_msg "CPU izleme düşük CPU tespit etti. Gensyn yeniden başlatılıyor..."
        exec rm -f "/tmp/gensyn_restart_needed"
        restart_app
    }
    
    # 30 saniye sonra tekrar kontrol et
    after 30000 check_cpu_restart
}

# Ana uygulama başlangıcı
log_msg "Gensyn Testnet otomatik yanıtlama ve izleme scripti başlatılıyor..."

# CPU izlemeyi başlat
start_cpu_monitor

# Ana komutu çalıştır
spawn bash -c "cd \$HOME && rm -rf gensyn-testnet && git clone https://github.com/zunxbt/gensyn-testnet.git && chmod +x gensyn-testnet/gensyn.sh && ./gensyn-testnet/gensyn.sh"

# CPU yeniden başlatma kontrolünü başlat
check_cpu_restart

# Yanıtları verme ve izleme
handle_prompts

# Script aktif olarak çalışıyor mesajı
log_msg "Script aktif olarak çalışıyor ve izliyor. Çıkmak için Ctrl+C..."

# Sonsuz bekleme - script sessizce çalışmaya devam eder
while {1} {
    # CPU izlemeyi kontrol et
    if {[file exists "/tmp/gensyn_restart_needed"]} {
        log_msg "CPU izleme düşük CPU tespit etti. Gensyn yeniden başlatılıyor..."
        exec rm -f "/tmp/gensyn_restart_needed"
        restart_app
    }
    
    # Gensyn işleminin hala çalışıp çalışmadığını kontrol et
    set gensyn_running [exec pgrep -f "gensyn-testnet/gensyn.sh" | wc -l]
    if {$gensyn_running == 0} {
        log_msg "Gensyn işlemi çalışmıyor. Yeniden başlatılıyor..."
        restart_app
    }
    
    # Her 30 saniyede bir kontrol et
    sleep 30
}
