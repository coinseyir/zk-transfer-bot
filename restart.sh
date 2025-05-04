#!/bin/bash

# Log dosyası oluştur
LOG_FILE="/root/gensyn_monitor.log"
touch $LOG_FILE

# Fonksiyon: Zaman damgalı log mesajı
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a $LOG_FILE
}

# Çalışan Gensyn süreçlerini kontrol et ve durdur
stop_gensyn() {
    log_message "Çalışan Gensyn süreçlerini kontrol ediliyor..."
    if pgrep -f "gensyn-testnet/gensyn.sh" > /dev/null; then
        log_message "Çalışan Gensyn süreci bulundu. Durduruluyor..."
        pkill -SIGINT -f "gensyn-testnet/gensyn.sh"
        sleep 10
        if pgrep -f "gensyn-testnet/gensyn.sh" > /dev/null; then
            log_message "Süreç hala çalışıyor. SIGINT tekrar gönderiliyor..."
            pkill -SIGINT -f "gensyn-testnet/gensyn.sh"
            sleep 5
            pkill -SIGINT -f "gensyn-testnet/gensyn.sh"
            sleep 5
            # Hala çalışıyorsa zorla sonlandır
            if pgrep -f "gensyn-testnet/gensyn.sh" > /dev/null; then
                log_message "Süreç zorla sonlandırılıyor..."
                pkill -9 -f "gensyn-testnet/gensyn.sh"
            fi
        fi
        log_message "Çalışan süreçler durduruldu."
        sleep 10
    fi
}

# Başlangıçta çalışan süreçleri durdur
stop_gensyn

# Fonksiyon: Sorular için yanıtları otomatik gönder
run_with_answers() {
    log_message "Gensyn testnet başlatılıyor..."
    
    # expect kullanarak sorulara otomatik yanıt ver
    expect << 'EOD'
        # Timeout süresini artır (15 dakika)
        set timeout 864400
        
        # Komutları çalıştır - $HOME yerine /root kullanalım
        spawn bash -c {cd /root && rm -rf gensyn-testnet && git clone https://github.com/zunxbt/gensyn-testnet.git && chmod +x gensyn-testnet/gensyn.sh && ./gensyn-testnet/gensyn.sh}
        
        # swarm.pem dosyası için soru
        expect {
            "Enter your choice (1 or 2):" {
                send "1\r"
                exp_continue
            }
            # Swarm seçimi için soru
            "Please select a swarm to join:" {
                sleep 1
                send "A\r"
                exp_continue
            }
            # Parametreler için soru
            "How many parameters (in billions)?" {
                sleep 1
                send "0.5\r"
                exp_continue
            }
            # Hugging Face Hub için soru
            "Would you like to push models you train in the RL swarm to the Hugging Face Hub?" {
                sleep 1
                send "N\r"
                exp_continue
            }
            # Ek olası sorular/çıktılar için
            "Do you want to continue?" {
                send "y\r"
                exp_continue
            }
            "Already have" {
                exp_continue
            }
            "Downloading" {
                exp_continue
            }
            "Installing" {
                exp_continue
            }
            eof {
                # Normal sonlanma
            }
            timeout {
                puts "Bir yanıt beklerken zaman aşımı oldu. Timeout süresi aşıldı (15 dakika)."
            }
        }
        
        # Sonsuz bir döngü için interact
        interact
EOD
}

# Fonksiyon: CPU kullanımını kontrol et
check_cpu_usage() {
    # Son 10 saniyedeki ortalama CPU kullanımını al
    cpu_usage=$(top -bn2 -d 0.5 | grep "Cpu(s)" | tail -n 1 | awk '{print $2+$4}')
    echo $cpu_usage
}

# Fonksiyon: Hata mesajlarını kontrol et
check_for_errors() {
    if tail -n 50 $LOG_FILE | grep -q "UnboundLocalError: local variable 'current_batch' referenced before assignment"; then
        log_message "Bilinen hata tespit edildi: 'current_batch' hatası"
        return 0
    fi
    return 1
}

# Ana döngü
while true; do
    log_message "Gensyn testnet başlatılıyor..."
    
    # Programı başlat ve arka planda çalıştır
    run_with_answers &
    GENSYN_PID=$!
    
    # CPU düşük kullanım sayacı
    low_cpu_count=0
    restart_needed=false
    
    # Program çalıştığı sürece izle
    while kill -0 $GENSYN_PID 2>/dev/null; do
        # 1 SAAT'te bir kontrol et (3600 saniye)
        log_message "CPU kontrolü için 1 saat bekleniyor..."
        sleep 3600
        
        # CPU kullanımını kontrol et
        cpu=$(check_cpu_usage)
        log_message "Mevcut CPU kullanımı: $cpu%"
        
        # CPU kullanımı %50'nin altındaysa sayacı artır
        if (( $(echo "$cpu < 50" | bc -l) )); then
            low_cpu_count=$((low_cpu_count+1))
            log_message "Düşük CPU kullanımı tespit edildi. Sayaç: $low_cpu_count"
            
            # 3 saat boyunca düşük CPU kullanımı
            if [ $low_cpu_count -ge 3 ]; then
                log_message "CPU kullanımı 3 saat boyunca %50'nin altında kaldı. Yeniden başlatılıyor..."
                restart_needed=true
                break  # İç döngüden çık, yeniden başlatma için
            fi
        else
            # Normal CPU kullanımında sayacı sıfırla
            low_cpu_count=0
        fi
        
        # Hata kontrolü
        if check_for_errors; then
            log_message "Hata tespit edildi, programı yeniden başlatma..."
            restart_needed=true
            break  # İç döngüden çık, yeniden başlatma için
        fi
    done
    
    # Eğer restart_needed = true ise veya süreç kendiliğinden sonlandıysa
    log_message "Süreç sonlandırılıyor..."
    
    # Süreç hala çalışıyorsa, düzgünce sonlandırmaya çalış
    if kill -0 $GENSYN_PID 2>/dev/null; then
        log_message "Ctrl+C gönderiliyor..."
        kill -SIGINT $GENSYN_PID
        sleep 10
        
        # İkinci kez Ctrl+C
        if kill -0 $GENSYN_PID 2>/dev/null; then
            log_message "İkinci Ctrl+C gönderiliyor..."
            kill -SIGINT $GENSYN_PID
            sleep 5
            
            # Üçüncü kez Ctrl+C
            kill -SIGINT $GENSYN_PID
            sleep 5
            
            # Eğer hala çalışıyorsa zorla sonlandır
            if kill -0 $GENSYN_PID 2>/dev/null; then
                log_message "Hala çalışıyor. Zorla sonlandırılıyor..."
                kill -9 $GENSYN_PID
            fi
        fi
    fi
    
    # Diğer süreçleri de temizle
    stop_gensyn
    
    log_message "Yeniden başlatmadan önce 30 saniye bekleniyor..."
    sleep 30
done
