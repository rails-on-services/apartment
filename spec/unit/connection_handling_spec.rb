# frozen_string_literal: true

require 'spec_helper'

describe Apartment::ConnectionHandling do
  describe '.modern_connection_handling?' do
    it 'returns true if Rails version is 6.0 or higher' do
      allow(ActiveRecord).to receive(:version).and_return(Gem::Version.new('6.0.0'))
      expect(Apartment::ConnectionHandling.modern_connection_handling?).to be true
      
      allow(ActiveRecord).to receive(:version).and_return(Gem::Version.new('7.0.0'))
      expect(Apartment::ConnectionHandling.modern_connection_handling?).to be true
    end
    
    it 'returns false if Rails version is below 6.0' do
      allow(ActiveRecord).to receive(:version).and_return(Gem::Version.new('5.2.0'))
      expect(Apartment::ConnectionHandling.modern_connection_handling?).to be false
    end
  end
  
  describe '.lease_apartment_connection' do
    before do
      allow(Apartment).to receive(:lease_connection)
      allow(Apartment).to receive(:connection)
    end
    
    it 'calls lease_connection in modern Rails' do
      allow(Apartment::ConnectionHandling).to receive(:modern_connection_handling?).and_return(true)
      Apartment::ConnectionHandling.lease_apartment_connection
      expect(Apartment).to have_received(:lease_connection)
    end
    
    it 'calls connection in older Rails' do
      allow(Apartment::ConnectionHandling).to receive(:modern_connection_handling?).and_return(false)
      Apartment::ConnectionHandling.lease_apartment_connection
      expect(Apartment).to have_received(:connection)
    end
  end
  
  describe '.with_apartment_connection' do
    let(:connection) { double('connection') }
    let(:block_result) { double('block_result') }
    
    before do
      allow(Apartment).to receive(:with_connection).and_yield(connection)
      allow(Apartment).to receive(:connection).and_return(connection)
    end
    
    context 'with a block' do
      it 'yields connection to the block in modern Rails' do
        allow(Apartment::ConnectionHandling).to receive(:modern_connection_handling?).and_return(true)
        
        expect { |b| Apartment::ConnectionHandling.with_apartment_connection(&b) }.to yield_with_args(connection)
      end
      
      it 'yields connection to the block in older Rails' do
        allow(Apartment::ConnectionHandling).to receive(:modern_connection_handling?).and_return(false)
        
        expect { |b| Apartment::ConnectionHandling.with_apartment_connection(&b) }.to yield_with_args(connection)
      end
    end
    
    context 'without a block' do
      it 'returns the result of lease_apartment_connection' do
        allow(Apartment::ConnectionHandling).to receive(:lease_apartment_connection).and_return(connection)
        
        result = Apartment::ConnectionHandling.with_apartment_connection
        
        expect(result).to eq(connection)
      end
    end
  end
  
  describe '.release_apartment_connection' do
    let(:connection_pool) { double('connection_pool') }
    
    before do
      allow(Apartment).to receive(:release_connection)
      allow(Apartment).to receive(:connection_class).and_return(double(connection_pool: connection_pool))
      allow(connection_pool).to receive(:release_connection)
    end
    
    it 'calls release_connection in modern Rails' do
      allow(Apartment::ConnectionHandling).to receive(:modern_connection_handling?).and_return(true)
      
      Apartment::ConnectionHandling.release_apartment_connection
      
      expect(Apartment).to have_received(:release_connection)
    end
    
    it 'calls connection_pool.release_connection in older Rails' do
      allow(Apartment::ConnectionHandling).to receive(:modern_connection_handling?).and_return(false)
      
      Apartment::ConnectionHandling.release_apartment_connection
      
      expect(connection_pool).to have_received(:release_connection)
    end
  end
end