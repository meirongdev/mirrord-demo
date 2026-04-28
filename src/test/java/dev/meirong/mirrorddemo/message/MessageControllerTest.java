package dev.meirong.mirrorddemo.message;

import static org.springframework.http.MediaType.APPLICATION_JSON;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.autoconfigure.EnableAutoConfiguration;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.ComponentScan;
import org.springframework.test.web.servlet.MockMvc;

@SpringBootTest(classes = MessageControllerTest.TestApplication.class)
@AutoConfigureMockMvc
class MessageControllerTest {

    @Autowired
    private MockMvc mockMvc;

    @Test
    void getCurrentMessageReturnsConfiguredPayload() throws Exception {
        mockMvc.perform(get("/api/messages/current"))
            .andExpect(status().isOk())
            .andExpect(content().contentTypeCompatibleWith(APPLICATION_JSON))
            .andExpect(jsonPath("$.message").value("hello from cluster"))
            .andExpect(jsonPath("$.handledBy").value("cluster"));
    }

    @Test
    void postCurrentMessageUpdatesTheStoredValue() throws Exception {
        mockMvc.perform(post("/api/messages/current")
                .contentType(APPLICATION_JSON)
                .content("""
                    {"message":"updated through local"}
                    """))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.message").value("updated through local"));

        mockMvc.perform(get("/api/messages/current"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.message").value("updated through local"));
    }

    @EnableAutoConfiguration
    @ComponentScan(basePackages = "dev.meirong.mirrorddemo")
    static class TestApplication {
    }
}
