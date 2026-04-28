package dev.meirong.mirrorddemo.message;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;

@Service
class MessageService {

    private final JdbcMessageRepository messageRepository;
    private final String appInstance;

    MessageService(JdbcMessageRepository messageRepository,
                   @Value("${demo.app-instance:cluster}") String appInstance) {
        this.messageRepository = messageRepository;
        this.appInstance = appInstance;
    }

    MessageRecord fetchCurrent() {
        return new MessageRecord(messageRepository.readCurrent(), appInstance);
    }

    MessageRecord updateCurrent(String message) {
        messageRepository.updateCurrent(message);
        return fetchCurrent();
    }
}
