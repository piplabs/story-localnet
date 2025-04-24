# docker compose -f docker-compose-validator1.yml build --no-cache
# docker compose -f docker-compose-validator2.yml build --no-cache
# docker compose -f docker-compose-validator3.yml build --no-cache
# docker compose -f docker-compose-validator4.yml build --no-cache
# docker compose -f docker-compose-bootnode1.yml build --no-cache
# docker compose -f docker-compose-monitoring.yml build --no-cache

docker compose -f docker-compose-monitoring.yml up -d 
docker compose -f docker-compose-bootnode1.yml up -d 
sleep 5
docker compose -f docker-compose-validator1.yml up -d 
docker compose -f docker-compose-validator2.yml up -d 
docker compose -f docker-compose-validator3.yml up -d 
docker compose -f docker-compose-validator4.yml up -d 