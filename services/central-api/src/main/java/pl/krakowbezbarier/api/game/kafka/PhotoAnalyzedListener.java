package pl.krakowbezbarier.api.game.kafka;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.stereotype.Component;
import pl.krakowbezbarier.api.config.KafkaConfig;
import pl.krakowbezbarier.api.game.CatchService;

@Component
public class PhotoAnalyzedListener {
    private final CatchService catches;
    private final ObjectMapper om;

    public PhotoAnalyzedListener(CatchService catches, ObjectMapper om) {
        this.catches = catches;
        this.om = om;
    }

    @KafkaListener(topics = KafkaConfig.PHOTO_ANALYZED, groupId = "central-api")
    public void onAnalyzed(String payload) throws Exception {
        catches.applyAnalysis(om.readValue(payload, Events.PhotoAnalyzed.class));
    }
}
