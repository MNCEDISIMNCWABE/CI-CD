CREATE OR REPLACE TABLE `hallowed-span-459710-s1.test_clustering.user_count` AS
SELECT
    COUNT(DISTINCT user_id) AS user_count
  FROM
    `hallowed-span-459710-s1.test_clustering.user-engagement`

