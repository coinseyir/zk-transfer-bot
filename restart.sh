#!/bin/bash

# Log dosyası oluştur
LOG_FILE="/root/gensyn_monitor.log"
touch $LOG_FILE

# Fonksiyon: Zaman damgalı log mesajı
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a $LOG_FILE
}

# Çalışan Gensyn süreçlerini kontrol et ve durdur
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

# Fonksiyon: Sorular için yanıtları otomatik gönder
run_with_answers() {
    log_message "Gensyn testnet başlatılıyor..."
    
    # Geçici bir output dosyası oluştur
    OUTPUT_FILE="/tmp/gensyn_output.log"
    
    # expect kullanarak SADECE başlangıç sorularını yanıtla, sonra çıkma
    expect -c "
        # Sorular için timeout (30 saniye)
        set timeout 15800
        
        # Komutları çalıştır
        spawn bash -c {cd /root && rm -rf gensyn-testnet && git clone https://github.com/zunxbt/gensyn-testnet.git && chmod +x gensyn-testnet/gensyn.sh && ./gensyn-testnet/gensyn.sh}
        
        # Log dosyasına çıktı yönlendir
        log_file $OUTPUT_FILE
        
        # swarm.pem dosyası için soru
        expect {
            \"Enter your choice (1 or 2):\" {
                send \"1\r\"
                exp_continue
            }
            # Swarm seçimi için soru
            \"Please select a swarm to join:\" {
                sleep 1
                send \"A\r\"
                exp_continue
            }
            # Parametreler için soru
            \"How many parameters (in billions)?\" {
                sleep 1
                send \"0.5\r\"
                exp_continue
            }
            # Hugging Face Hub için soru
            \"Would you like to push models you train in the RL swarm to the Hugging Face Hub?\" {
                sleep 1
                send \"N\r\"
                # Tüm sorular tamamlandı, artık interact moduna geç
                puts \"\nTüm sorulara yanıt verildi, uygulamanın çalışmasına izin veriliyor...\n\"
                interact
            }
            # Ek olası sorular için
            \"Do you want to continue?\" {
                send \"y\r\"
                exp_continue
            }
            timeout {
                puts \"Bir yanıt beklerken zaman aşımı oldu (5 dakika). Etkileşimli moda geçiliyor...\"
                interact
            }
        }
    " >> $LOG_FILE 2>&1 &
    
    # Expect scriptinin PID'sini saklayalım
    EXPECT_PID=$!
    
    # Arka planda çalışan expect'in işlemciye bağlanmasını bekle
    sleep 5
    
    # Gerçek uygulama PID'sini bulalım
    APP_PID=$(pgrep -f "gensyn-testnet/gensyn.sh")
    
    # Expect process'ini sonlandır, uygulama kendi kendine çalışmaya devam etsin
    if [ -n "$EXPECT_PID" ]; then
        log_message "Tüm sorulara yanıt verildi, expect sonlandırılıyor ve uygulama kendi devam edecek."
        kill $EXPECT_PID 2>/dev/null
    fi
    
    # Gerçek uygulama PID'sini döndür
    echo $APP_PID
}

# Fonksiyon: CPU kullanımını kontrol et
check_cpu_usage() {
    # Son 10 saniyedeki ortalama CPU kullanımını al
    cpu_usage=$(top -bn2 -d 0.5 | grep "Cpu(s)" | tail -n 1 | awk '{print $2+$4}')
    echo $cpu_usage
}

# Fonksiyon: Hata mesajlarını kontrol et
check_for_errors() {
    if grep -q "UnboundLocalError: local variable 'current_batch' referenced before assignment" "/tmp/gensyn_output.log"; then
        log_message "Bilinen hata tespit edildi: 'current_batch' hatası"
        return 0
    fi
    return 1
}

# Ana döngü
while true; do
    log_message "Gensyn testnet yeniden başlatılıyor..."
    
    # Output dosyasını temizle
    echo "" > /tmp/gensyn_output.log
    
    # Programı başlat ve gerçek PID'yi al
    GENSYN_PID=$(run_with_answers)
    
    # PID'yi logla
    log_message "Gensyn uygulaması başlatıldı, PID: $GENSYN_PID"
    
    # CPU düşük kullanım sayacı
    low_cpu_count=0
    
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
                break
            fi
        else
            low_cpu_count=0
        fi
        
        # Hata kontrolü - sürekli log dosyasını kontrol et
        if check_for_errors; then
            log_message "Hata tespit edildi, programı yeniden başlatma..."
            log_message "Ctrl+C gönderiliyor..."
            # 2-3 kez Ctrl+C gönder
            kill -SIGINT $GENSYN_PID
            sleep 5
            kill -SIGINT $GENSYN_PID
            sleep 5
            kill -SIGINT $GENSYN_PID
            sleep 5
            # Eğer hala çalışıyorsa zorla sonlandır
            if kill -0 $GENSYN_PID 2>/dev/null; then
                log_message "Hala çalışıyor. Zorla sonlandırılıyor..."
                kill -9 $GENSYN_PID
            fi
            break
        fi
    done
    
    log_message "Program sonlandı, 30 saniye bekleniyor..."
    sleep 30
done
