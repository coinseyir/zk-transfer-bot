#!/bin/bash

# Benzersiz tanımlayıcı oluştur - çakışmaları önlemek için
UNIQUE_ID="gensyn_auto_$(date +%s)"
OUTPUT_FILE="/tmp/${UNIQUE_ID}_output.txt"
PIPE="/tmp/${UNIQUE_ID}_pipe"
LOG_FILE="/tmp/${UNIQUE_ID}_log.txt"

# Log fonksiyonu
log() {
    echo "$(date): $1" | tee -a $LOG_FILE
}

# Mevcut Gensyn işlemini kontrol et
check_existing_gensyn() {
    if pgrep -f "gensyn-testnet/gensyn.sh" > /dev/null; then
        log "⚠️ Gensyn zaten çalışıyor. Bu scriptin çalışmakta olan uygulamayı duraklatmadan sadece izleme yapacağını unutmayın."
        return 0
    else
        return 1
    fi
}

# Function to run the main command and handle responses
run_gensyn() {
    # Check if already running
    if check_existing_gensyn; then
        log "Mevcut Gensyn işlemini kullanıyorum"
        GENSYN_PID=$(pgrep -f "gensyn-testnet/gensyn.sh")
        return
    fi

    # Setup output and input mechanisms
    touch $OUTPUT_FILE
    rm -f $PIPE
    mkfifo $PIPE
    
    log "Gensyn başlatılıyor..."
    log "Çıktılar burada: $OUTPUT_FILE"
    log "Giriş pipe: $PIPE"

    # Scripti başlat
    cd $HOME && rm -rf gensyn-testnet && git clone https://github.com/zunxbt/gensyn-testnet.git && \
    chmod +x gensyn-testnet/gensyn.sh && ./gensyn-testnet/gensyn.sh < $PIPE > $OUTPUT_FILE 2>&1 &
    
    # PID'i kaydet
    GENSYN_PID=$!
    log "Gensyn PID: $GENSYN_PID"
    
    # Wait for the first prompt about swarm.pem
    log "swarm.pem sorusu bekleniyor..."
    while ! grep -q "You already have an existing swarm.pem file" $OUTPUT_FILE; do
        sleep 2
        # İşlemin yaşayıp yaşamadığını kontrol et
        if ! ps -p $GENSYN_PID > /dev/null; then
            log "İşlem swarm.pem sorusu gelmeden önce kapandı"
            return 1
        fi
    done
    log "swarm.pem sorusuna yanıt veriliyor: 1"
    echo "1" > $PIPE  # Mevcut swarm.pem kullan
    
    # Swarm seçim sorusu için bekle
    log "Swarm seçim sorusu bekleniyor..."
    while ! grep -q "Please select a swarm to join" $OUTPUT_FILE; do
        sleep 2
        if ! ps -p $GENSYN_PID > /dev/null; then
            log "İşlem swarm seçim sorusu gelmeden önce kapandı"
            return 1
        fi
    done
    log "Swarm seçim sorusuna yanıt veriliyor: A"
    echo "A" > $PIPE  # Math swarm'ı seç
    
    # Parametre sorusu için bekle
    log "Parametre sorusu bekleniyor..."
    while ! grep -q "How many parameters" $OUTPUT_FILE; do
        sleep 2
        if ! ps -p $GENSYN_PID > /dev/null; then
            log "İşlem parametre sorusu gelmeden önce kapandı"
            return 1
        fi
    done
    log "Parametre sorusuna yanıt veriliyor: 0.5"
    echo "0.5" > $PIPE  # 0.5 milyar parametre seç
    
    # Hugging Face sorusu için bekle
    log "Hugging Face sorusu bekleniyor..."
    while ! grep -q "Would you like to push models you train in the RL swarm to the Hugging Face Hub" $OUTPUT_FILE; do
        sleep 2
        if ! ps -p $GENSYN_PID > /dev/null; then
            log "İşlem Hugging Face sorusu gelmeden önce kapandı"
            return 1
        fi
    done
    log "Hugging Face sorusuna yanıt veriliyor: N"
    echo "N" > $PIPE  # Hugging Face'e yükleme yapma
    
    log "Tüm sorular yanıtlandı. Şimdi izleniyor..."
    
    # Pipe'ı temizle ama çıktı dosyasını izleme için tut
    rm -f $PIPE
}

# Hata paternlerini kontrol et
check_for_errors() {
    if grep -q "failed to connect to bootstrap peers" "$OUTPUT_FILE" || \
       grep -q "Daemon failed to start" "$OUTPUT_FILE" || \
       grep -q "hivemind.p2p.p2p_daemon_bindings.utils.P2PDaemonError" "$OUTPUT_FILE"; then
        return 0  # Hata bulundu
    else
        return 1  # Hata yok
    fi
}

# İşlemi yeniden başlat
restart_process() {
    log "Hatalara bağlı olarak Gensyn yeniden başlatılıyor..."
    
    # Ctrl+C sinyallerini birkaç kez gönder
    for i in {1..3}; do
        kill -SIGINT $GENSYN_PID 2>/dev/null
        sleep 2
    done
    
    # İşlemin sonlandığından emin ol
    kill $GENSYN_PID 2>/dev/null
    
    # Yeniden başlatmadan önce bekle
    sleep 5
    
    # Çıktı dosyasını temizle
    echo "" > $OUTPUT_FILE
    
    # İşlemi yeniden başlat
    run_gensyn
    log "Gensyn yeniden başlatıldı, PID: $GENSYN_PID"
}

# CPU kullanımını izle
monitor_cpu() {
    local low_cpu_count=0
    local threshold=50
    local check_interval=60  # Her dakika kontrol et
    local max_low_cpu=60     # Bir saat (60 kontrol)
    
    while true; do
        # İşlemin CPU kullanımını al
        if ! ps -p $GENSYN_PID > /dev/null; then
            log "Gensyn işlemi artık çalışmıyor, CPU izleme durduruldu"
            return
        fi
        
        local cpu_usage=$(ps -p $GENSYN_PID -o %cpu= | awk '{print int($1)}')
        
        log "Mevcut CPU kullanımı: ${cpu_usage}%"
        
        if [ "$cpu_usage" -lt "$threshold" ]; then
            low_cpu_count=$((low_cpu_count + 1))
            log "Düşük CPU sayacı: $low_cpu_count/$max_low_cpu"
            
            if [ "$low_cpu_count" -ge "$max_low_cpu" ]; then
                log "CPU kullanımı ${threshold}% altında 1 saat boyunca kaldı, yeniden başlatılıyor..."
                restart_process
                low_cpu_count=0
            fi
        else
            low_cpu_count=0
        fi
        
        sleep $check_interval
    done
}

# Başarılı bağlantıyı izle
monitor_success() {
    while true; do
        if [ ! -f "$OUTPUT_FILE" ]; then
            sleep 30
            continue
        fi
        
        if grep -q "Connected to Gensyn Testnet" "$OUTPUT_FILE"; then
            log "✅ Gensyn Testnet'e başarıyla bağlanıldı!"
        fi
        sleep 60
    done
}

# Temizlik fonksiyonu
cleanup() {
    log "Temizlik yapılıyor ve çıkılıyor..."
    kill $MONITOR_CPU_PID 2>/dev/null
    kill $MONITOR_SUCCESS_PID 2>/dev/null
    rm -f $PIPE
    log "Temizlik tamamlandı. Log dosyası: $LOG_FILE"
    exit 0
}

# Trap sinyalleri
trap cleanup SIGINT SIGTERM

# Ana çalıştırma
log "Gensyn Testnet otomatik yanıt sistemi başlatılıyor..."
log "Benzersiz ID: $UNIQUE_ID"

# İlk işlemi başlat
run_gensyn

if [ -z "$GENSYN_PID" ]; then
    log "Gensyn işlemi başlatılamadı. Lütfen hataları kontrol edin ve tekrar deneyin."
    exit 1
fi

# CPU izlemeyi arka planda başlat
monitor_cpu &
MONITOR_CPU_PID=$!

# Başarı izlemeyi başlat
monitor_success &
MONITOR_SUCCESS_PID=$!

# Ana izleme döngüsü
log "Ana izleme döngüsü başlatıldı"
while true; do
    # İşlem öldüyse yeniden başlat
    if ! ps -p $GENSYN_PID > /dev/null; then
        log "Gensyn işlemi kapandı, yeniden başlatılıyor..."
        # Çıktı dosyasını temizle
        echo "" > $OUTPUT_FILE
        run_gensyn
        log "Gensyn yeniden başlatıldı, PID: $GENSYN_PID"
    fi
    
    # Hatalar için logları kontrol et
    if check_for_errors; then
        restart_process
    fi
    
    sleep 30
done
