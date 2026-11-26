# ЛР № 5. Внедрение Liquibase
Проект воспроизводит модель интернет-магазина из ЛР № 2.
Для повторения установите Java, Liquibase CLI 4.31.1 с JDBC-драйвером PostgreSQL и PostgreSQL 18.
Создайте отдельную пустую БД с правом создания схем у пользователя подключения.
В liquibase.properties укажите её JDBC URL и пользователя. Передайте пароль через переменную среды LIQUIBASE_COMMAND_PASSWORD.
В каталоге проекта выполните:
```powershell
liquibase validate
liquibase update
liquibase history
liquibase rollback-count 1
liquibase update
liquibase history
liquibase update
```
В evidence/run.txt сохранены вывод CLI и контрольные запросы с результатами.
Контрольный запрос приведён в evidence/check.sql. Запустите его в той же БД после каждого изменения.
