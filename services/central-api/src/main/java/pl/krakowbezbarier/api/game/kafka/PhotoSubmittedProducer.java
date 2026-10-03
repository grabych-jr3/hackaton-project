package pl.krakowbezbarier.api.game.kafka;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.stereotype.Component;
import pl.krakowbezbarier.api.config.KafkaConfig;

import java.util.concurrent.CompletableFuture;

@Component
public class PhotoSubmittedProducer {
    private final KafkaTemplate<String, String> kafka;
    private final ObjectMapper om;

    public PhotoSubmittedProducer(KafkaTemplate<String, String> kafka, ObjectMapper om) {
        this.kafka = kafka;
        this.om = om;
    }

    public CompletableFuture<?> send(Events.PhotoSubmitted event) {
        try {
            return kafka.send(KafkaConfig.PHOTO_SUBMITTED, event.catchId(), om.writeValueAsString(event));
        } catch (Exception e) {
            return CompletableFuture.failedFuture(e);
        }
    }
}
