# Dockerfile for backend service

# Use a base image that includes Python
FROM python:3.9

# Install net-tools for netstat command
RUN apt-get update && apt-get install -y net-tools

# Set the working directory
WORKDIR /app

# Copy the backend files to the container
COPY . /app

# Install Python dependencies
RUN pip install -r requirements.txt

# Expose the port the application will run on
EXPOSE 5000

# Run the backend server
CMD ["python", "backend.py"]