package dev.meirong.mirrorddemo.message;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/messages")
class MessageController {

    private final MessageService messageService;

    MessageController(MessageService messageService) {
        this.messageService = messageService;
    }

    @GetMapping("/current")
    MessageRecord current() {
        return messageService.fetchCurrent();
    }

    @PostMapping("/current")
    MessageRecord update(@RequestBody UpdateMessageRequest request) {
        return messageService.updateCurrent(request.message());
    }

    record UpdateMessageRequest(String message) {
    }
}
