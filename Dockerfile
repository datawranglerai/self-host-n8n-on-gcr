FROM docker.n8n.io/n8nio/n8n:latest

# Copy the script and ensure it has proper permissions
COPY startup.sh /
USER root
RUN chmod +x /startup.sh

# Install community nodes
RUN npm install -g n8n-nodes-apify n8n-nodes-scrapeninja n8n-nodes-globals n8n-nodes-deepseek n8n-nodes-youtube-transcription-kasha @watzon/n8n-nodes-perplexity

USER node
EXPOSE 5678

# Use shell form to help avoid exec format issues
ENTRYPOINT ["/bin/sh", "/startup.sh"]
