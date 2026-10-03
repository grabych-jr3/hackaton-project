package pl.krakowbezbarier.api;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.scheduling.annotation.EnableScheduling;

@SpringBootApplication
@EnableScheduling
public class CentralApiApplication {
    public static void main(String[] args) {
        SpringApplication.run(CentralApiApplication.class, args);
    }
}
