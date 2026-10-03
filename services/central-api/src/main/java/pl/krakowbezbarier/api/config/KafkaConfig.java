package pl.krakowbezbarier.api.config;

import org.apache.kafka.clients.admin.NewTopic;
import org.apache.kafka.common.TopicPartition;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.kafka.config.TopicBuilder;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.kafka.listener.DeadLetterPublishingRecoverer;
import org.springframework.kafka.listener.DefaultErrorHandler;
import org.springframework.util.backoff.FixedBackOff;

@Configuration
public class KafkaConfig {
    public static final String PHOTO_SUBMITTED = "photo.submitted";
    public static final String PHOTO_ANALYZED = "photo.analyzed";
    public static final String PHOTO_ANALYZED_DLQ = "photo.analyzed.dlq";

    @Bean NewTopic photoSubmitted() { return TopicBuilder.name(PHOTO_SUBMITTED).partitions(1).replicas(1).build(); }
    @Bean NewTopic photoAnalyzed() { return TopicBuilder.name(PHOTO_ANALYZED).partitions(1).replicas(1).build(); }
    @Bean NewTopic photoAnalyzedDlq() { return TopicBuilder.name(PHOTO_ANALYZED_DLQ).partitions(1).replicas(1).build(); }

    /** 3 attempts in total, then the record goes to photo.analyzed.dlq. */
    @Bean
    DefaultErrorHandler kafkaErrorHandler(KafkaTemplate<String, String> template) {
        var recoverer = new DeadLetterPublishingRecoverer(template,
                (rec, ex) -> new TopicPartition(PHOTO_ANALYZED_DLQ, -1));
        return new DefaultErrorHandler(recoverer, new FixedBackOff(1000L, 2));
    }
}
