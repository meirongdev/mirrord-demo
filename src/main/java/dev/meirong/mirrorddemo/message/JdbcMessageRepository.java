package dev.meirong.mirrorddemo.message;

import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

@Repository
class JdbcMessageRepository {

    private final JdbcClient jdbcClient;

    JdbcMessageRepository(JdbcClient jdbcClient) {
        this.jdbcClient = jdbcClient;
    }

    String readCurrent() {
        return jdbcClient.sql("select message from demo_message where id = 1")
            .query(String.class)
            .single();
    }

    void updateCurrent(String message) {
        jdbcClient.sql("update demo_message set message = :message where id = 1")
            .param("message", message)
            .update();
    }
}
