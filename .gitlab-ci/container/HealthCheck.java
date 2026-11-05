import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;

public class HealthCheck {
    public static void main(String[] args) throws Exception {
        HttpResponse<Void> response = HttpClient.newHttpClient()
            .send(HttpRequest.newBuilder().uri(URI.create("http://localhost:8080/health")).build(), 
                  HttpResponse.BodyHandlers.discarding());
        
        if (response.statusCode() != 200) {
            System.exit(1);
        }
    }
}