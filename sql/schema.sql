USE deadlock_lab;
CREATE TABLE IF NOT EXISTS phone_number_usages (
  id BIGINT NOT NULL AUTO_INCREMENT,
  phone_number VARCHAR(255) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  histories JSON NOT NULL,
  created_at DATETIME(6) NOT NULL,
  updated_at DATETIME(6) NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY idx_phone_xxxxx (phone_number)
) ENGINE=InnoDB;
